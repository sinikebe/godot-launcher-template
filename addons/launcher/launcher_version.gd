extends RefCounted
## Which build of the launcher this game is carrying.
##
## VERSION is maintained by hand in the template and travels with the code.
## The other three are stamped by ci/sync_launcher.sh when a game pulls the
## launcher in, so a game can always say exactly which revision it is running --
## which is the first question worth asking when a launcher bug is reported.

## Bump when anything under addons/launcher/ changes. ci/check_launcher_version.sh
## fails a pull request that does not, because "bump it when it matters" on its
## own did not work: this sat at 1.0.0 through four changes to the launcher, one
## of which removed a public constant.
##
## Which component moves is still a judgement, and the only one that really
## matters is MAJOR -- a game's existing code no longer compiles against this
## launcher. That is what went unsignalled at 1.0.0, and it is why this is 2.0.0
## rather than 1.0.1: UpdateService.REQUEST_TIMEOUT was removed after 1.0.0 was
## declared, and BuildInfo.launcher_source() was added.
const VERSION: String = "2.0.0"

## Template commit this copy came from, or "local" inside the template itself.
const COMMIT: String = "local"

## RFC3339 date this copy was synced, or "" inside the template.
const SYNCED_AT: String = ""

## Repository it was synced from, or "" inside the template.
const SOURCE: String = ""
