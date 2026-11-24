# Project conventions

Use the Rails conventions for controllers, views and Minitest. Keep the public HTTP contract, page renderer client and HTML parsers independently testable. Run `bin/ci` before publishing.

After each substantial milestone, use the installed `review-agent` skill in a fresh reviewer session. Provide the base and head commits, the acceptance criteria and the test commands. Resolve actionable findings, rerun the affected checks and ask the reviewer to verify the fixes before proceeding.
