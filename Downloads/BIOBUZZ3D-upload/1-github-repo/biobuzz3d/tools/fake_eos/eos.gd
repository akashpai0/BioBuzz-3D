extends RefCounted
## SIMULATED EOS, FOR THE TESTS ONLY. The same namespaces, option classes,
## enums and static calls that NetEOS uses from the real EOSG `eos.gd`, with
## the same names and values, so NetEOS runs its real code against it.
## Nothing here talks to Epic.

enum Result { Success = 0, NotFound = 13, DuplicateNotAllowed = 14, InvalidUser = 33 }

static func is_success(p_result) -> bool:
	if typeof(p_result) == TYPE_DICTIONARY:
		p_result = p_result["result_code"]
	return int(p_result) == Result.Success

static func result_str(p_result) -> String:
	if typeof(p_result) == TYPE_DICTIONARY:
		p_result = p_result["result_code"]
	for k in Result:
		if int(Result[k]) == int(p_result):
			return k
	return str(p_result)

enum ExternalCredentialType { None = -1, Epic = 0, DeviceidAccessToken = 10 }

class Connect:
	class Credentials extends RefCounted:
		var type: int
		var token = null
	class UserLoginInfo extends RefCounted:
		var display_name: String
	class LoginOptions extends RefCounted:
		var credentials
		var user_login_info
	class CreateDeviceIdOptions extends RefCounted:
		var device_model: String
	class ConnectInterface:
		static func create_device_id(options: CreateDeviceIdOptions) -> void:
			var ieos: Object = Engine.get_singleton("IEOS")
			var path := "user://fake_eos_device_%s.txt" % String(OS.get_environment("FAKE_EOS_DEVICE"))
			var res := 14
			if not FileAccess.file_exists(path):
				var f := FileAccess.open(path, FileAccess.WRITE)
				f.store_string("%08x%08x%08x%08x" % [randi(), randi(), randi(), randi()])
				f.close()
				res = 0
			ieos.call_deferred("emit_signal", "connect_interface_create_device_id_callback", {"result_code": res})

class Lobby:
	enum LobbyPermissionLevel { PublicAdvertised = 0, JoinViaPresence = 1, InviteOnly = 2 }
	class CreateLobbyOptions extends RefCounted:
		var bucket_id: String
		var max_lobby_members: int
		var permission_level: int
		var presence_enabled: bool
		var allow_invites: bool
		var enable_join_by_id: bool
		var disable_host_migration: bool

class P2P:
	enum NATType { Unknown = 0, Open = 1, Moderate = 2, Strict = 3 }
	enum RelayControl { NoRelays = 0, AllowRelays = 1, ForceRelays = 2 }
