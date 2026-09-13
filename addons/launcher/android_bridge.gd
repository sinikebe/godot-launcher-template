class_name AndroidBridge
extends RefCounted
## Thin, best-effort wrapper over the Android APIs the updater needs.
##
## Every call here is optional: on a non-Android build, or on a device where a
## JNI call fails, each method degrades to a no-op / false and the updater falls
## back to something that still works (usually "ask the user to do it manually").
## Nothing in here is allowed to hard-crash the menu.

const _FLAG_ACTIVITY_NEW_TASK := 0x10000000
const _ACTION_MANAGE_UNKNOWN_APP_SOURCES := "android.settings.MANAGE_UNKNOWN_APP_SOURCES"


static func is_available() -> bool:
	return OS.get_name() == "Android" and Engine.has_singleton("AndroidRuntime")


static func _activity() -> Object:
	if not is_available():
		return null
	var runtime := Engine.get_singleton("AndroidRuntime")
	if runtime == null:
		return null
	var activity: Object = runtime.call("getActivity")
	return activity


## True when the OS will let us hand it an APK to install.
##
## Returns true on anything older than Android 8, where there is no per-app
## gate, and true when we simply cannot tell -- the install intent itself is the
## real check, and the system installer prompts for the permission on its own if
## it is missing. This is only used to show a clearer message up front.
static func can_install_packages() -> bool:
	var activity := _activity()
	if activity == null:
		return false
	var pm: Object = activity.call("getPackageManager")
	if pm == null or _had_exception():
		return true
	var allowed: Variant = pm.call("canRequestPackageInstalls")
	if _had_exception() or typeof(allowed) != TYPE_BOOL:
		# Pre-Oreo: the method does not exist and there is no gate to check.
		return true
	return bool(allowed)


## Sends the user to the "allow installs from this app" settings screen.
## Returns false if we could not open it, in which case the caller should just
## tell the user to enable it by hand.
static func open_install_settings() -> bool:
	var activity := _activity()
	if activity == null:
		return false
	var intent_class: Variant = JavaClassWrapper.wrap("android.content.Intent")
	var uri_class: Variant = JavaClassWrapper.wrap("android.net.Uri")
	if intent_class == null or uri_class == null or _had_exception():
		return false

	var intent: Variant = intent_class.new(_ACTION_MANAGE_UNKNOWN_APP_SOURCES)
	if intent == null or _had_exception():
		return false

	var package_name: Variant = activity.call("getPackageName")
	if not _had_exception() and typeof(package_name) == TYPE_STRING:
		var uri: Variant = uri_class.parse("package:%s" % package_name)
		if uri != null and not _had_exception():
			intent.setData(uri)
	intent.addFlags(_FLAG_ACTIVITY_NEW_TASK)
	activity.call("startActivity", intent)
	return not _had_exception()


## Hands the downloaded APK to the system package installer.
##
## Goes through OS.shell_open() rather than building the Intent ourselves:
## Godot's Android implementation already routes a file path through its bundled
## FileProvider (authority "<package>.fileprovider"), resolves the MIME type to
## application/vnd.android.package-archive, and attaches a read-URI grant so the
## installer can actually open a file that lives in our private files dir.
static func install_apk(absolute_path: String) -> bool:
	if not FileAccess.file_exists(absolute_path):
		push_error("[AndroidBridge] APK missing: %s" % absolute_path)
		return false
	return OS.shell_open(ProjectSettings.globalize_path(absolute_path)) == OK


## Relaunches the app so a freshly mounted content pack takes effect.
## Uses the restart helper Godot already ships inside its Android library.
static func restart_app() -> bool:
	var activity := _activity()
	if activity == null:
		return false
	var phoenix: Variant = JavaClassWrapper.wrap("org.godotengine.godot.utils.ProcessPhoenix")
	if phoenix == null or _had_exception():
		return false
	phoenix.triggerRebirth(activity)
	return not _had_exception()


## Drains and reports the pending JNI exception, if any.
static func _had_exception() -> bool:
	if not is_available():
		return false
	var exception: Variant = JavaClassWrapper.get_exception()
	if exception == null:
		return false
	push_warning("[AndroidBridge] JNI call raised: %s" % exception)
	return true
