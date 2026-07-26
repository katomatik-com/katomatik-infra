# ONE-SHOT: adopt the pre-existing, operator-created `katomatik` realm into
# Terraform state instead of recreating it (ADR-0015 hands realm ownership to
# Terraform; the realm itself already exists and must survive the handover).
#
# A config-driven `import` block (Terraform >= 1.5) makes the adoption visible
# in `plan` before anything happens — the plan will read:
#
#     keycloak_realm.katomatik: Preparing import... [id=katomatik]
#     ~ resource "keycloak_realm" "katomatik" { ... }
#     Plan: 1 to import, 1 to change, 0 to destroy.
#
# The in-place change is only the attributes realm.tf pins that the operator
# never set (display_name, password_policy). "0 to destroy" is the line to
# check: it confirms the realm is being adopted, not replaced.
#
# >>> DELETE THIS FILE after the first successful apply. <<<
# The realm is in state at that point and the block has no further purpose;
# leaving it behind makes every future plan re-evaluate a finished migration.
import {
  to = keycloak_realm.katomatik
  id = "katomatik"
}
