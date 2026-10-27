CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE "OWNER_ROLE";
ALTER ROLE "{{name}}" SET role = 'OWNER_ROLE';
