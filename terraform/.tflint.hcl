config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
  version = "0.16.1"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
}

plugin "aws" {
  enabled = true
  version = "0.50.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
