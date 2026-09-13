extends RefCounted
## Which build of the launcher this game is carrying.
##
## VERSION is maintained by hand in the template and travels with the code.
## The other three are stamped by ci/sync_launcher.sh when a game pulls the
## launcher in, so a game can always say exactly which revision it is running --
## which is the first question worth asking when a launcher bug is reported.

## Bump in the template when the launcher changes meaningfully.
const VERSION: String = "1.0.0"

## Template commit this copy came from, or "local" inside the template itself.
const COMMIT: String = "local"

## RFC3339 date this copy was synced, or "" inside the template.
const SYNCED_AT: String = ""

## Repository it was synced from, or "" inside the template.
const SOURCE: String = ""
