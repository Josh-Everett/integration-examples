#
# METADATA
# title: PoC probe for verified test-result statements
# description: >-
#   Reports every test-result statement that survived signature and task-trust
#   verification, and every one that was only signature-verified.
#
package poc_probe

import rego.v1

import data.lib.intoto
import data.lib.metadata

# METADATA
# title: Verified test-result statement found
# description: Lists each test-result statement in lib.intoto.verified_statements.
# custom:
#   short_name: verified_test_statement
#   failure_msg: 'verified: name=%s timestamp=%s result=%s subject=%s'
#
warn contains result if {
	some s in intoto.verified_statements_by_predicate(intoto.predicate_test_result)
	result := metadata.result_helper(rego.metadata.chain(), [
		object.get(s.predicate, ["configuration", 0, "name"], "<none>"),
		object.get(s.predicate, "timestamp", "<none>"),
		object.get(s.predicate, "result", "<none>"),
		object.get(s, ["subject", 0, "digest", "sha256"], "<none>"),
	])
}

# METADATA
# title: Signature-verified test-result statement found
# description: >-
#   Lists each test-result statement whose Chains provenance verified, before
#   task trust is applied. Present but not in the list above means a task in
#   the provenance is untrusted.
# custom:
#   short_name: associated_test_statement
#   failure_msg: 'signature-verified: name=%s timestamp=%s result=%s'
#
warn contains result if {
	some a in intoto.associated_statement_provenances_by_predicate(intoto.predicate_test_result)
	s := a.statement
	result := metadata.result_helper(rego.metadata.chain(), [
		object.get(s.predicate, ["configuration", 0, "name"], "<none>"),
		object.get(s.predicate, "timestamp", "<none>"),
		object.get(s.predicate, "result", "<none>"),
	])
}

# METADATA
# title: No verified test-result statement
# description: >-
#   Warns when lib.intoto.verified_statements holds no test-result statement.
#   Expected on per-architecture child manifests, which carry no statement.
# custom:
#   short_name: verified_test_statement_missing
#   failure_msg: no test-result statement survived verification
#
warn contains result if {
	count(intoto.verified_statements_by_predicate(intoto.predicate_test_result)) == 0
	result := metadata.result_helper(rego.metadata.chain(), [])
}
