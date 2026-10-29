# AWS demo day: what only AWS can prove

Everything in this repository has passed static checks, and the platform has run on kind. These items depend on AWS behaviour that neither kind nor `terraform test` can show: KMS encryption contexts, service-to-service KMS calls, EBS encryption at launch, and real teardown. Run them in order on the one day the environment exists. **This checklist has not been run yet.**

**Before you start**
- The owner runs everything: it spends money (`docs/cost.md`, about $34/day) and touches a real account.
- **Pre-flight: both service-linked roles exist.** The platform key's policy names them, and KMS rejects a policy whose principal does not exist yet. `scripts/up.sh` creates them if they are missing; check them before the first apply, and run Terraform by hand only after this check:
  ```
  aws iam get-role --role-name AWSServiceRoleForAutoScaling --query Role.Arn
  aws iam get-role --role-name AWSServiceRoleForEC2Spot --query Role.Arn
  ```
  Expected: two ARNs. If one returns `NoSuchEntity`: `aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com` (or `spot.amazonaws.com`). Otherwise `terraform apply` fails on the platform key with `MalformedPolicyDocumentException: Policy contains a statement with one or more invalid principals`.
- Bring the environment up: `FINCORE_AWS=confirm scripts/up.sh`. Add `FINCORE_PROFILE=small-team` for that profile, and use the same value for `down.sh`.
- Set up the shell:
  ```
  export KUBECONFIG=.kube/aws-config
  tf() { terraform -chdir=terraform/envs/demo output -raw "$1"; }
  CDE_KEY=$(terraform -chdir=terraform/envs/demo output -json kms_key_arns | jq -r .cde)
  PLATFORM_KEY=$(terraform -chdir=terraform/envs/demo output -json kms_key_arns | jq -r .platform)
  ```
- CloudTrail delivers events with a delay of up to about 5 minutes; wait before looking an event up.
- Save screenshots to `docs/evidence/aws/`. **Redact the account ID, domain and IP addresses** before committing: none may enter the repository.
- When an item fails, apply its fix, run `make check`, apply, and run the item again. Log the fix in `docs/decisions-log.md`.

## a) A payment end to end

Proves the `kms:EncryptionContext:aws:sqs:arn` condition: payments-api encrypts with the CDE key for the queue, and the notifier decrypts.

1. Create a payment:
   ```
   curl -sS -X POST "$(tf api_url)/v1/payments" -H 'Content-Type: application/json' \
     -H "Idempotency-Key: demo-day-$(date +%s)" \
     -d '{"merchant_id":"m_demo","amount":1250,"currency":"USD","card_token":"tok_visa"}'
   kubectl -n fincore logs deploy/webhook-sink --since=2m | grep payment
   ```
2. Look up the KMS calls in CloudTrail:
   ```
   for e in GenerateDataKey Decrypt; do
     aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=$e --max-results 50 \
       --query 'Events[].CloudTrailEvent' --output text | jq -c 'select(.requestParameters.encryptionContext["aws:sqs:arn"] != null)
         | {event: .eventName, role: .userIdentity.sessionContext.sessionIssuer.userName, via: .sourceIPAddress, ctx: .requestParameters.encryptionContext, error: .errorCode}'
   done
   ```

**Expected:**
- The payment is `captured`, and the webhook sink logs a delivery for it.
- CloudTrail shows `GenerateDataKey` by `fincore-demo-payments-api` and `Decrypt` by `fincore-demo-notifier`. Both come through `sqs.amazonaws.com`, both have `aws:sqs:arn` = the payment-events queue, and neither has an `errorCode`.

**Screenshot:** the payment response next to the two CloudTrail events, with the account ID redacted.

**If it fails:**
- **payments-api** answers 5xx and logs `KMS.AccessDeniedException` on `SendMessage`, or the notifier logs it on `ReceiveMessage`: compare the CloudTrail event's `encryptionContext` and `kms:ViaService` with the conditions in `terraform/modules/eks/main.tf` (`payments_api`, `notifier`), and correct the key name or value. The test in `terraform/modules/eks/tests` must change with them.
- **No webhook arrives:** this is a delivery problem, not a KMS one ([payment failures](runbooks/payment-failures-spike.md)).

## b) A poison message reaches the DLQ while the notifier is decrypt-only

The SQS documentation does not say which principal's KMS permissions the automatic move to a dead-letter queue uses. The notifier may only `Decrypt`, and only for the main queue.

1. Send a message the notifier cannot parse. As an admin: the CDE key allows this through SQS.
   ```
   aws sqs send-message --queue-url "$(tf payment_events_queue_url)" --message-body 'not-json-demo-day'
   ```
2. Watch the logs: the notifier logs `malformed event; leaving for DLQ` on each receive. It is moved after 5 receives at a 30 s visibility timeout, about 3 minutes.
   ```
   kubectl -n fincore logs deploy/notifier -f | grep malformed
   ```
3. Check where the message ended up:
   ```
   aws sqs get-queue-attributes --queue-url "$(tf payment_events_dlq_url)" --attribute-names ApproximateNumberOfMessages
   aws sqs receive-message --queue-url "$(tf payment_events_dlq_url)" --attribute-names All   # as the admin
   ```
4. Find out who encrypted for the DLQ: in CloudTrail, the `GenerateDataKey` events whose `aws:sqs:arn` is the DLQ (as in a).

**Expected:**
- The message is in the DLQ with `ApproximateReceiveCount` 5, and the main queue is empty.
- CloudTrail shows which principal generated the DLQ's data key, and that it did so without an `errorCode`. Record that principal in `docs/compliance-mapping.md`: it answers the open question.

**Screenshot:**
- the notifier's five `malformed` log lines;
- the DLQ message's attributes;
- the CloudTrail `GenerateDataKey` event for the DLQ context.

**If it fails:** the message stays in the main queue past 5 receives, or CloudTrail shows `AccessDenied` for the DLQ context under the notifier's role. The move then runs on the receiver's permissions. Add one statement to `notifier` in `terraform/modules/eks/main.tf`:
- `kms:GenerateDataKey` on the CDE key;
- `kms:ViaService` = `sqs.<region>.amazonaws.com`;
- `kms:EncryptionContext:aws:sqs:arn` = the **DLQ** ARN only.

Extend the test with it, and record in `compliance-mapping.md` why the notifier needs it.

## c) Aurora storage, Performance Insights and the RDS log group under `OnlyThroughServices`

The CDE key denies data use to every IAM principal outside SQS, RDS, Secrets Manager and EC2. RDS, Performance Insights and CloudWatch Logs must still work.

1. Check that Aurora's storage is encrypted with the CDE key:
   ```
   aws rds describe-db-clusters --db-cluster-identifier "$(tf aurora_cluster_id)" \
     --query 'DBClusters[0].{Encrypted:StorageEncrypted,Key:KmsKeyId,PI:PerformanceInsightsEnabled,PIKey:PerformanceInsightsKMSKeyId}'
   ```
2. Check Performance Insights: open it in the RDS console for the writer, and look at the top SQL for the last 15 minutes.
3. Check the RDS log group:
   ```
   aws logs describe-log-groups --log-group-name-prefix "/aws/rds/cluster/fincore-demo" --query 'logGroups[].{n:logGroupName,k:kmsKeyId}'
   aws logs tail "/aws/rds/cluster/fincore-demo/postgresql" --since 15m | head
   ```
4. Look for denials on the CDE key:
   ```
   aws cloudtrail lookup-events --lookup-attributes AttributeKey=ResourceName,AttributeValue="$CDE_KEY" --max-results 200 \
     --query 'Events[].CloudTrailEvent' --output text | jq -c 'select(.errorCode != null) | {t: .eventTime, e: .eventName, who: .userIdentity.arn, via: .requestParameters.encryptionContext, err: .errorCode}'
   ```

**Expected:**
- `Encrypted` is true, and `Key` and `PIKey` both equal `$CDE_KEY`.
- Performance Insights shows load and SQL.
- The log group's `kmsKeyId` is `$CDE_KEY`, and it receives lines (a slow query, or the connection log).
- The denial query returns nothing, apart from item d's deliberate calls.

**Screenshot:** the Performance Insights dashboard, the `describe-db-clusters` output, and the empty denial query.

**If it fails:** CloudTrail shows `AccessDenied` on the CDE key for an AWS service. Its event says which `kms:ViaService` it used (Performance Insights is the likely one). Add that service to `via_services` of `module "cde_kms"` in `terraform/envs/demo/main.tf`, and to the test in `terraform/modules/kms/tests`. If no ViaService is present at all, the call came from a service principal; scope it like `CloudWatchLogs` in `terraform/modules/kms/main.tf`.

## d) An admin with `kms:*` cannot use the CDE key directly (portfolio evidence)

As an administrator (an `AdministratorAccess` role):
```
aws kms encrypt --key-id "$CDE_KEY" --plaintext fileb://<(printf demo)
aws kms generate-data-key --key-id "$CDE_KEY" --key-spec AES_256
printf 'not-a-real-ciphertext-demo-day' > /tmp/blob
aws kms decrypt --key-id "$CDE_KEY" --ciphertext-blob fileb:///tmp/blob
```

**Expected:**
- **Encrypt** and **GenerateDataKey:** `AccessDeniedException` with "... with an explicit deny in a resource-based policy". The key policy's `OnlyThroughServices` statement overrides the admin's `kms:*`.
- **Decrypt:** no real CDE ciphertext can be obtained outside the services, and that is the control. So this test uses an invalid blob. If KMS authorises before it parses the blob, the call shows the same explicit deny. If it parses first, it answers `InvalidCiphertextException`; then the Encrypt and GenerateDataKey denials are the evidence. Write down which one AWS returned.
- **Contrast:** the same admin can still read a CDE secret through Secrets Manager (`aws secretsmanager describe-secret --secret-id fincore-payments-db`). That is the via-service path, which IAM governs.

**Screenshot:** the three CLI responses, plus the matching CloudTrail events with `errorCode: AccessDenied`. Redact the account ID.

**If it fails:** if any of these calls succeeds, the deny statement is not in effect.
- Check the key policy: `aws kms get-key-policy --key-id "$CDE_KEY" --policy-name default`.
- The `OnlyThroughServices` statement must be present, with `aws:PrincipalIsAWSService` = `false` and `kms:ViaService` listing only the four services.

## e) Node root volumes: CDE on the CDE key, general (Spot) on the platform key

```
for role in cde spot; do
  sel=$([ $role = cde ] && echo 'fincore.io/node-role=cde' || echo 'karpenter.sh/capacity-type=spot')
  id=$(kubectl get nodes -l "$sel" -o jsonpath='{.items[0].spec.providerID}' | awk -F/ '{print $NF}')
  aws ec2 describe-instances --instance-ids "$id" --query "Reservations[].Instances[].{role:'$role',lifecycle:InstanceLifecycle,type:InstanceType}"
  aws ec2 describe-volumes --filters Name=attachment.instance-id,Values="$id" \
    --query "Volumes[].{role:'$role',vol:VolumeId,enc:Encrypted,key:KmsKeyId}"
done
```
If no Spot node exists yet, scale something general (not CDE) up until Karpenter launches one. Spot is the general NodePools' first choice.

**Expected:**
- The CDE node is on-demand (`lifecycle` empty), and its root volume is encrypted with `$CDE_KEY`.
- A general node is `lifecycle: spot`, and its root volume is encrypted with `$PLATFORM_KEY`. A system node's volume also uses `$PLATFORM_KEY`.

**Screenshot:** the `describe-instances` and `describe-volumes` output for both nodes, next to `kubectl get nodes -L fincore.io/node-role,karpenter.sh/nodepool,karpenter.sh/capacity-type`.

**If it fails:** a NodeClaim stays un-launched, and Karpenter logs a `CreateFleet` error naming KMS (`Client.InvalidKMSKey.InvalidState`, or `AccessDenied`). Look up the denied call in CloudTrail (`CreateGrant` or `GenerateDataKeyWithoutPlaintext` on the key).
- **A Spot node is refused, with "EBS volume cannot be encrypted … grant AWSServiceRoleForEC2Spot access":** the platform key's `SpotUse`/`SpotGrants` statements are missing, or the role did not exist when the key policy was written. Check both:
  - `aws kms get-key-policy --key-id "$PLATFORM_KEY" --policy-name default | jq -r .Policy | jq '.Statement[] | select(.Sid | startswith("Spot"))'`
  - the pre-flight above.

  Then re-apply. On-demand general nodes would still launch meanwhile (the NodePools' fallback), so a missing Spot node is a symptom too.
- **Principal is the Karpenter controller role:** compare its `kms:ViaService` with `local.karpenter_ebs_kms_statements` in `terraform/modules/eks/main.tf`.
- **Principal is `AWSServiceRoleForEC2Fleet`:** EC2 Fleet uses its own service-linked role for encrypted volumes. Let it use both keys the way `AutoScalingUse`/`AutoScalingGrants` do (`terraform/modules/kms/main.tf`, a variable next to `autoscaling_service_role`), and extend the kms test.

## f) A Velero restore without CDE Secrets, with RTO measured

1. Check that the newest CDE backup holds no Secret. The second command should print nothing.
   ```
   B=$(kubectl -n velero get backups -l velero.io/schedule-name=velero-cde-without-secrets --sort-by=.metadata.creationTimestamp -o name | tail -1 | cut -d/ -f2)
   kubectl -n velero exec deploy/velero -- /velero backup describe "$B" --details | grep -i -A3 'v1/Secret'
   ```
2. Simulate losing the zone. Stop Argo CD from healing it first: the root app, then the zone's apps.
   ```
   kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":null}}'
   for a in cde-base payments-api ledger; do kubectl -n argocd patch application $a --type merge -p '{"spec":{"syncPolicy":null}}'; done
   T0=$(date -u +%s); kubectl delete namespace fincore-cde --wait=true
   ```
3. Restore by following [`runbooks/disaster-recovery.md`](runbooks/disaster-recovery.md), steps 4 to 7, with the CDE schedule only.
   - Note `T1` when `kubectl -n fincore-cde wait externalsecret --all --for=condition=Ready` returns.
   - Note `T2` at the first successful payment (item a).
4. Put the sync policies back. The root app restores the child apps' policies itself (self-heal):
   ```
   kubectl -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
   ```

**Expected:**
- No Secret in the backup.
- After the restore, each Secret in `fincore-cde` is owned by its ExternalSecret, with a `creationTimestamp` after `T0`.
- RTO = `T2 − T0`. Record it, and `T1 − T0`, in `docs/evidence/aws/dr.md` next to kind's 18 min 14 s. They measure different things: a namespace on AWS, the whole cluster on kind.

**Screenshot:**
- the backup's resource list, with no Secrets;
- `kubectl -n fincore-cde get externalsecrets,secrets`, showing Ready, the owners and the timestamps;
- the timeline.

**If it fails:**
- **An ExternalSecret stays not Ready:** look in CloudTrail for `AccessDenied` on `Decrypt` with `encryptionContext.SecretARN`. Then compare the policy `external_secrets` in `terraform/modules/eks/main.tf` with the secret's real ARN (Secrets Manager appends a random suffix; the ARNs come from Terraform, so they should match).
- **Pods stay in `CreateContainerConfigError` after the Secrets exist:** restart the Rollouts (runbook step 6).
- **A Secret did end up in the backup:** check `gitops/envs/aws/values/velero.yaml`, and the `make check` assertion that guards it.

## g) `down.sh` leaves nothing billable

```
FINCORE_AWS=confirm scripts/down.sh          # same FINCORE_PROFILE as up.sh
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=fincore --query 'ResourceTagMappingList[].ResourceARN'
aws kms list-aliases --query "Aliases[?starts_with(AliasName, 'alias/fincore')]"
```

**Expected:**
- `down.sh` ends with "nothing billable left".
- The tagging query lists only resources pending deletion or the Terraform state bucket (`terraform/bootstrap`, kept on purpose). Tags can linger on deleted resources for a while.
- KMS keys are `PendingDeletion` (7 or 30 days): keys pending deletion are not billed.
- The next day, Cost Explorer filtered on `Project=fincore` shows only the state bucket's cents.

**Screenshot:** the final `down.sh` output, and Cost Explorer for the following day.

**If it fails:** a leftover is something a controller created at runtime, or something that outlived its owner. Typical cases:
- an ALB or target group (Ingress deleted too late);
- EBS volumes (a PVC deleted after its node);
- ENIs (VPC CNI);
- a CloudWatch log group created by a service rather than by Terraform.

Delete it by hand, and add the case to `scripts/down.sh` (its ordered steps, and step 6's leftover check).
