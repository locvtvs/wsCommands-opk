package wsCommands;




#   __________________          _-_
#   \__by_locvtvs____|)____.---'---`---.____
#                ||    \----._________.----/
#                ||     / ,'   `---'
#             ___||_,--'  -._ 
#            /___   2.0.0  ||(-
#                `---._____-'




use strict;




#===================================================================================
# Openkore dependencies
#===================================================================================
use Plugins;
use Commands;
use Log qw ( warning message error );
use Globals;
#===================================================================================
#===================================================================================




#===================================================================================
# WebSocket + JSON related dependencies
#===================================================================================
use IO::Socket::INET;
use Protocol::WebSocket::Handshake::Client;
use Protocol::WebSocket::Frame;
use Errno qw(EAGAIN EWOULDBLOCK EINPROGRESS);
use JSON;
#===================================================================================
#===================================================================================
use Time::HiRes qw(sleep);
use Encode;
#===================================================================================
#===================================================================================




#===================================================================================
#  Default WebSocket server URL (protocol, domain and port)
#===================================================================================
#
#  $url will be replaced by 'ws_url' value from config.txt
#  on ws_start3() subroutine.
#
#===================================================================================
my $protocol = "ws";
my $domain = "localhost";
my $port = 3000;
my $url = $protocol."://".$domain.":".$port."/";
#===================================================================================
#===================================================================================




#===================================================================================
#  General flags
#===================================================================================
my $start3_finished = 0;
#===================================================================================
#===================================================================================




#===================================================================================
#  WebSocket flags
#===================================================================================
my $connected = 0;
my $warned_disconnected = 0; # prevents the flood of "Disconnected" message
#===================================================================================
#===================================================================================




#===================================================================================
#  WebSocket related objects
#===================================================================================
my $sock;
my $handshake;
my $frame;
my $buffer = "";
#===================================================================================
#===================================================================================




#===================================================================================
#  WebSocket timestamps
#===================================================================================
#
#  This plugin act as a WebSocket client,
#  so it need to check if the connection is still alive often.
#
#  When the plugin sends a ping, your WS server must response a pong (opcode 10).
#
#  On NodeJs 'ws' library, pong is sent automatic (usually)... BUT a workaround is 
#  required now: server will pong twice (manually once) to keep client alive.
#
#  $ws_heartbeat_interval will be replaced by 'ws_hb_interval' from config.txt
#
#===================================================================================
my $last_pong = time; # TODO: needs review
my $last_heartbeat = time; # TODO: needs review
my $ws_heartbeat_interval = 3; # (seconds) TODO: needs review
#===================================================================================
#===================================================================================




#===================================================================================
#  Useful constants
#===================================================================================
use constant {
	PLUGIN_NAME => "wsCommands", 
	PLUGIN_VERSION => "2.0.0",
	CMD_MAIN => "ws", # console command
	VALUE_PLACEHOLDER => "{{value}}", # for replacing values in strings
};
#===================================================================================
#===================================================================================


#===================================================================================
#  Custom convention for the server to handle the types of messages sent
#  by this client.
#===================================================================================
use constant {
	WS_RECEIVED_COMMAND_HOOK => "wsCommands/command_received",
	WS_RECEIVED_MESSAGE_HOOK => "wsCommands/message_received",
	WS_TYPE_HS_DONE => "HANDSHAKE_DONE",
	WS_TYPE_CLT_EMIT_SV_EV => "CLT_EMIT_SV_EVENT",
	WS_TYPE_CLT_MSG_SV => "CLT_TO_SV_MSG",
	WS_TYPE_CLT_MSG_CLT => "CLT_TO_CLT_MSG",
	WS_TYPE_CLT_MSG_ALL => "CLT_TO_ALL_MSG",
	WS_TYPE_CLT_MSG_OTHERS => "CLT_TO_OTHERS_MSG",
	WS_TYPE_CLT_MSG_GROUP => "CLT_TO_GROUP_MSG",
	WS_TYPE_CLT_MSG_GROUP_EXCEPT => "CLT_TO_GROUP_EXCEPT_MSG",
	WS_TYPE_CLT_MSG_GROUP_DC => "CLT_TO_GROUP_MSG_DC",
	WS_TYPE_CLT_CLT => "CLT_TO_CLT_CMD",
	WS_TYPE_CLT_ALL => "CLT_TO_ALL_CMD",
	WS_TYPE_CLT_OTHERS => "CLT_TO_OTHERS_CMD",
	WS_TYPE_CLT_GROUP => "CLT_TO_GROUP_CMD",
	WS_TYPE_CLT_GROUP_EXCEPT => "CLT_TO_GROUP_EXCEPT_CMD",
	WS_TYPE_RES_CMD => "RESPONSE:".VALUE_PLACEHOLDER,
};
#===================================================================================
#===================================================================================


#===================================================================================
#  Default responses
#===================================================================================
use constant {
	WS_RES_CMD_RECV => "Command received: ".VALUE_PLACEHOLDER,
};
#===================================================================================
#===================================================================================




#===================================================================================
#	Plugin registration
#===================================================================================
Plugins::register	(
	PLUGIN_NAME,
	"WebSocket client for sending and receiving Openkore commands.",
	\&unloadPlugin
);
#===================================================================================
#===================================================================================




#===================================================================================
#	Console command registration
#===================================================================================
my $pluginCmds = Commands::register(
	[
		CMD_MAIN, 
		"use ".CMD_MAIN." \"<command> <args>\"", 
		\&cmdWsc
	],
);
#===================================================================================
#===================================================================================




#===================================================================================
#	Hooks
#===================================================================================
my $hooks = Plugins::addHooks (
	# -------------------------------------------
	# TODO: clean code required here...
	# -------------------------------------------
		['start3', \&ws_start3],
		['start3', \&ws_close],

		['pos_load_config.txt', \&ws_start3],
		['pos_load_config.txt', \&ws_tick],

		['initialized', \&ws_start3],
		['initialized', \&ws_close],
		['initialized', \&ws_tick],

		['mainLoop_pre', \&ws_tick],
		['mainLoop_post', \&ws_tick],
		['Network::serverSend/pre', \&ws_tick],
		['Network::stateChanged', \&ws_tick],
		['Network::clientSend', \&ws_tick],
		['Network::clientRecv', \&ws_tick],
		['packet_pre/actor_display', \&ws_tick],
		['packet/actor_display', \&ws_tick],
		['disconnected', \&ws_mapserver_dc],
		
		[WS_RECEIVED_COMMAND_HOOK, \&ws_on_command_received],
		[WS_RECEIVED_MESSAGE_HOOK, \&ws_on_message_received],
	# -------------------------------------------
	# -------------------------------------------
);
#===================================================================================
#===================================================================================




sub ws_on_command_received {
	my (undef, $args) = @_;
	wscWarning("Running command: $args->{cmd}\n");
	Commands::run($args->{cmd});
}




sub ws_on_message_received {
	my (undef, $args) = @_;
	wscWarning("Message received: $args->{msg}\n");
}




#===================================================================================
#  In case the plugin is reloaded, $url will be formatted again.
#===================================================================================
ws_tick();
ws_start3();
#===================================================================================
#===================================================================================




#=============================================================================================
#  Console command
#=============================================================================================
sub cmdWsc {
	my (undef, $argStr) = @_;
	

	my $sub_cmd;
	my $sub_args;


	if ($argStr =~ m/(\w+) (.*)$/) {
		$sub_cmd = $1;
		$sub_args = $2;
	} elsif ($argStr =~ m/(\w+)$/) {
		$sub_cmd = $1;
	}




	if ($sub_cmd eq "ws_mapserver_dc") {
		ws_mapserver_dc();
	}
	
	elsif ($sub_cmd eq "ws_close") {
		ws_close();
	}
	
	elsif ($sub_cmd eq "ws_start3") {
		ws_start3();
	}
	
	elsif ($sub_cmd eq "ws_tick") {
		ws_tick();
	}
	
	elsif ($sub_cmd eq "sendmsg") {




		#=======================================================================================
		#  ws sendmsg <target_id> <message>
		#=======================================================================================
		# TODO: improve this regex...
		if ($sub_args =~ /^(?!(?:-g|--group|-a|--all|-ge|--groupexcept|-mg|-mygroup|-mge|--mygroupexcept|-sv|--server|-o|--others|-ms|--myself))(\S+)\s+(.*)$/) {
			my %content = (
				ws_target_id => $1,
				msg => $2,
			);
			
			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_CLT, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -my|--myself <message>
		#=======================================================================================
		if ($sub_args =~ /^(?:-ms|--myself)\s+(.*)$/) {
			
			
			unless(defined $config{ws_id}) {
				wscError("No WebSocket Client ID, check the 'ws_id' value on your config.txt.\n");
				return;
			}

			
			my %content = (
				ws_target_id => defined $config{ws_id} ? $config{ws_id} : -1,
				msg => $1,
			);


			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_CLT, \%content);
			ws_send_message($response_json);
			
			
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -a <message>
		#  ws sendmsg --all <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-a|--all)\s+(.*)$/) {
			my %content = (
				msg => $1,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_ALL, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -o <message>
		#  ws sendmsg --others <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-o|--others)\s+(.*)$/) {
			my %content = (
				msg => $1,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_OTHERS, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================
		
		
		#=======================================================================================
		#  ws sendmsg -sv <message>
		#  ws sendmsg --server <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-sv|--server)\s+(.*)$/) {
			my %content = (
				msg => $1,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_SV, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -g <group_id> <message>
		#  ws sendmsg --group <group_id> <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-g|--group)\s+(\S+)\s+(.*)$/) {
			my %content = (
				ws_group_id => $1,
				cmd => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_GROUP, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -ge <group_id> <message>
		#  ws sendmsg --groupexcept <group_id> <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-ge|--groupexcept)\s+(\S+)\s+(.*)$/) {
			my %content = (
				ws_group_id => $1,
				cmd => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_GROUP_EXCEPT, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendmsg -mg <message>
		#  ws sendmsg --mygroup <message>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-mg|--mygroup)\s+(.*)$/) {
			
			
			unless(defined $config{ws_group}) {
				wscError("No WebSocket group, check the 'ws_group' value on your config.txt.\n");
				return;
			}

			
			my %content = (
				ws_group_id => defined $config{ws_group} ? $config{ws_group} : -1,
				msg => $2,
			);


			my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_GROUP, \%content);
			ws_send_message($response_json);
			
			
		}
		#=======================================================================================
		#=======================================================================================
		else {
			wscError(
				"Invalid command arguments.\n".
				"Use:\n". 
				"    " . CMD_MAIN . " sendmsg <target_id> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-a|--all> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-o|--others> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-sv|--server> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-ms|--myself> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-g|--group> <group_id> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-ge|--groupexcept> <group_id> <message>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendmsg <-mg|--mygroup> <message>\n" # .
				# "  " . "or:\n".
				# TODO: "    " . CMD_MAIN . " sendmsg <-mge|--mygroupexcept> <message>\n"
			);
		}
		#=======================================================================================
		#=======================================================================================
	}
	
	elsif ($sub_cmd eq "emitsv") {
		if ($sub_args =~ /^"([^"]+)"\s+(.*)$/) {
			my %content = (
				ev => $1,
				msg => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_EMIT_SV_EV, \%content);
			ws_send_message($response_json);
		}
	}
	
	
	elsif ($sub_cmd eq "sendcmd") {
		#=======================================================================================
		#  ws sendcmd <target_id> <console command>
		#=======================================================================================
		# TODO: improve this regex...
		if ($sub_args =~ /^(?!(?:-g|--group|-a|--all|-ge|--groupexcept|-mg|--mygroup|-mge|--mygroupexcept|-sv|--server|-o|--others|-ms|--myself))(\S+)\s+(.*)$/) {
			my %content = (
				ws_target_id => $1,
				cmd => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_CLT, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================
		
		
		#=======================================================================================
		#  ws sendcmd -my|--myself <console command>
		#=======================================================================================
		if ($sub_args =~ /^(?:-ms|--myself)\s+(.*)$/) {
			
			
			unless(defined $config{ws_id}) {
				wscError("No WebSocket Client ID, check the 'ws_id' value on your config.txt.\n");
				return;
			}

			
			my %content = (
				ws_target_id => defined $config{ws_id} ? $config{ws_id} : -1,
				cmd => $1,
			);


			my $response_json = ws_build_response_json(WS_TYPE_CLT_CLT, \%content);
			ws_send_message($response_json);


		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendcmd -a <console command>
		#  ws sendcmd --all <console command>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-a|--all)\s+(.*)$/) {
			my %content = (
				cmd => $1,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_ALL, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendcmd -o <console command>
		#  ws sendcmd --others <console command>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-o|--others)\s+(.*)$/) {
			my %content = (
				cmd => $1,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_OTHERS, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendcmd -g <group_id> <console command>
		#  ws sendcmd --group <group_id> <console command>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-g|--group)\s+(\S+)\s+(.*)$/) {
			my %content = (
				ws_group_id => $1,
				cmd => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_GROUP, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendcmd -ge <group_id> <console command>
		#  ws sendcmd --groupexcept <group_id> <console command>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-ge|--groupexcept)\s+(\S+)\s+(.*)$/) {
			my %content = (
				ws_group_id => $1,
				cmd => $2,
			);

			my $response_json = ws_build_response_json(WS_TYPE_CLT_GROUP_EXCEPT, \%content);
			ws_send_message($response_json);
		}
		#=======================================================================================
		#=======================================================================================


		#=======================================================================================
		#  ws sendcmd -mg <console command>
		#  ws sendcmd --mygroup <console command>
		#=======================================================================================
		elsif ($sub_args =~ /^(?:-mg|--mygroup)\s+(.*)$/) {
			
			
			unless(defined $config{ws_group}) {
				wscError("No WebSocket group, check the 'ws_group' value on your config.txt.\n");
				return;
			}
			
			
			my %content = (
				ws_group_id => defined $config{ws_group} ? $config{ws_group} : -1,
				cmd => $1,
			);


			my $response_json = ws_build_response_json(WS_TYPE_CLT_GROUP, \%content);
			ws_send_message($response_json);
			
			
		}
		#=======================================================================================
		#=======================================================================================
		else {
			wscError(
				"Invalid command arguments.\n".
				"Use:\n". 
				"    " . CMD_MAIN . " sendcmd <target_id> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-a|--all> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-o|--others> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-ms|--myself> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-g|--group> <group_id> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-ge|--groupexcept> <group_id> <console command>\n".
				"  " . "or:\n".
				"    " . CMD_MAIN . " sendcmd <-mg|--mygroup> <console command>\n" # .
				# "  " . "or:\n".
				# TODO: "    " . CMD_MAIN . " sendcmd <-mge|--mygroupexcept> <console command>\n"
			);
		}
		#=======================================================================================
		#=======================================================================================
	}
	#===========================================================================================
	#===========================================================================================


	#===========================================================================================
	#  ws help
	#===========================================================================================
	elsif ($sub_cmd eq "help") {
		wscWarning(
			"wsCommands ".PLUGIN_VERSION." by locvtvs - https://github.com/locvtvs\n".
			"-- Commands:\n".
			"--- " . CMD_MAIN . " sendcmd:\n".

			"         " . CMD_MAIN . " sendcmd <target_id> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-a|--all> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-o|--others> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-ms|--myself> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-g|--group> <group_id> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-ge|--groupexcept> <group_id> <console command>\n".
			"         " . CMD_MAIN . " sendcmd <-mg|--mygroup> <console command>\n".
			# TODO: "         " . CMD_MAIN . " sendcmd <-mge|--mygroupexcept> <console command>\n".
			"--- " . CMD_MAIN . " sendmsg:\n".
			"         " . CMD_MAIN . " sendmsg <target_id> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-a|--all> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-o|--others> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-sv|--server> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-ms|--myself> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-g|--group> <group_id> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-ge|--groupexcept> <group_id> <message>\n".
			"         " . CMD_MAIN . " sendmsg <-mg|--mygroup> <message>\n" .
			# TODO: "         " . CMD_MAIN . " sendmsg <-mge|--mygroupexcept> <message\n".
			"--- " . CMD_MAIN . " emitsv:\n".
			"         " . CMD_MAIN . " emitsv \"event name\" <stringified data>\n".
			"--- Debug:\n".
			"         " . CMD_MAIN . " wsclose\n".
			"         " . CMD_MAIN . " wsstart3\n".
			"         " . CMD_MAIN . " wstick\n".
			"         " . CMD_MAIN . " help\n"
		);
	}
	#===========================================================================================
	#===========================================================================================


	#===========================================================================================
	#===========================================================================================
	else {
		wscError("Invalid command. Use: ws help\n");
	}
	#===========================================================================================
	#===========================================================================================
}
#=============================================================================================
#=============================================================================================




sub ws_start3 {
	# wscWarning("ws_start3 called.\n");
	#===================================================================================
	#  ws_tick() will only run after the config.txt is loaded, since the plugin needs
	#  the value of 'ws_url' from that file in order to connect to the server.
	#  Therefore, we need wait for the 'start3' (or 'pos_load_config.txt') hook.
	#
	#  More info at:
	#  https://openkore.com/wiki/hooks#start3
	#===================================================================================
	$start3_finished = 1;
	#===================================================================================
	#===================================================================================


	#===================================================================================
	#  Gets the url from config.txt (ws_url) and adds "/" at the end if necessary.
	#
	#  Example (config.txt):
	#			ws_url ws://localhost:3000/
	#		or:
	#			ws_url ws://localhost:3000
	#
	#===================================================================================
	if (defined $config{ws_url}) {
		my $tmp_config_ws_url = $config{ws_url};
		# Extracts protocol, domain and port from 'ws_url'.
		if ($tmp_config_ws_url =~ /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^:\/]+):([0-9]+)/) {
			$protocol = $1;
			$domain = $2;
			$port = $3;
		}
		$url = $protocol."://".$domain.":".$port."/";
	}
	#===================================================================================
	#===================================================================================
}




sub ws_tick {
	#===================================================================================
	#  Checks whether it's connected to the WebSocket server
	#  every time the 'mainLoop_post' hook is called.
	#
	#  control/config.txt must be already loaded for this to occur ('start3' and 
	#  'pos_load_config.txt' hook).
	#
	#  More info at:
	#  https://openkore.com/wiki/hooks#start3
	#  https://openkore.com/wiki/hooks#mainLoop_post
	#  https://openkore.com/wiki/hooks#Hook_List
	#===================================================================================
	if ($start3_finished) { # only if the start3 hook has already ben called
			# wscWarning("ws_tick called.\n");
			ws_connect_tcp();
			ws_send_handshake();
			ws_advance_handshake();
			ws_process_frames();
			ws_heartbeat(); # TODO: needs review
	}
	#===================================================================================
	#===================================================================================
}



#===================================================================================
#  WebSocket client life-cycle that doesn't block Openkore mainLoop.
#===================================================================================
#-----------------------------------------------------------------------------------


sub ws_connect_tcp {
	# wscWarning("ws_connect_tcp called 1.\n");
	return if $sock; # already connected or trying
	# wscWarning("ws_connect_tcp called 2.\n");

	$sock = IO::Socket::INET->new(
			PeerHost => $domain,
			PeerPort => $port,
			Proto    => 'tcp',
			Blocking => 0,
	);

	if ($sock) {
			$connected = 0;
	}
}


#-----------------------------------------------------------------------------------


sub ws_send_handshake {
	# wscWarning("ws_send_handshake called 1.\n");
	return unless $sock && !$handshake;
	# wscWarning("ws_send_handshake called 2.\n");

	$handshake = Protocol::WebSocket::Handshake::Client->new(url => $url);
	print $sock $handshake->to_string;
}


#-----------------------------------------------------------------------------------


sub ws_advance_handshake {
	# wscWarning("ws_advance_handshake called 1.\n");
	return unless $sock && $handshake && !$connected;
	# wscWarning("ws_advance_handshake called 2.\n");


	my $read = "";
	my $n = sysread($sock, $read, 4096);
	return unless $n;


	$buffer .= $read;

	unless ($handshake->is_done) {
		$handshake->parse($buffer);
		if ($handshake->is_done) {
			$frame = Protocol::WebSocket::Frame->new;
			$connected = 1;
			my $elapsed_pong = time - $last_pong;
			$last_pong = time;
			wscWarning("Handshake completed! Last pong: ".$elapsed_pong." second(s) ago.\n");
			$warned_disconnected = 0;


			#==========================================================================
			#  Send the first response to the server.
			#  Check the constants section at the beginning of this script.
			#==========================================================================
			my %content = (
				ws_group_id => defined $config{ws_group} ? $config{ws_group} : -1,
			);
			my $response_json = ws_build_response_json(WS_TYPE_HS_DONE, \%content);
			ws_send_message($response_json);
			#==========================================================================
			#==========================================================================
		}
	}
}


#-----------------------------------------------------------------------------------


sub ws_process_frames {
	# wscWarning("ws_process_frames called 1.\n");
	return unless $sock;
	# wscWarning("ws_process_frames called 2.\n");


	my $read = "";
	my $n = sysread($sock, $read, 4096);

	# If the server closed the connection
	if (defined $n && $n == 0) {
			unless ($warned_disconnected) {
				wscWarning("Server closed the connection\n");
				$warned_disconnected = 1;
			}
			ws_close();
			return;
	}


	# If a non-transient read error occurred
	if (
			!defined $n && 
			$! != EAGAIN && # was working on Linux without EWOULDBLOCK, still required
			$! != EWOULDBLOCK && # fixes Windows issues, but not tested on Linux yet
			$! != EINPROGRESS # required to reconnect
	) {
		# warning("Read error: $!\n");
		ws_close();
		return;
	}


	$buffer .= $read if $n;
	return unless $frame;  # before handshake
	
	$frame->append($buffer);
	for (my $msg = $frame->next; defined $msg; $msg = $frame->next) {
		my $opcode = $frame->opcode;
		if ($opcode == 10) {
			my $elapsed_pong = time - $last_pong;
			$last_pong = time;
			# wscWarning("Pong received. Last pong: ".$elapsed_pong." second(s) ago.\n");
		}
		elsif ($opcode == 9) { wscWarning("Ping received\n"); }
		elsif ($opcode == 8) { wscWarning("Close received\n"); ws_close(); }
		elsif ($opcode == 1 || $opcode == 2) {
			#================================================================================
			#================================================================================
			#  The server must send a message starting with 'do' for it to be
			#  considered a console command.
			#
			#		Examples:
			#
			#			do sit
			#			do reload config
			#			do plugin reload wsCommands
			#			do macro stop
			#			do is Red Potion
			#			do relog 0
			#
			#================================================================================
			my $json_data = decode_json($msg);
			unless ($json_data->{msg} =~ /^do\s+(.*)/) {
				#============================================================================
				# 
				#  If it doesn't start with 'do ', the message will only be
				#  printed to the console. (see the subroutine 'ws_on_message_received')
				#
				#  It's useful for automacros that
				#  uses 'console /<regexp>/' condition.
				#
				#  You can get the message using hooks.
				#  Check 'WS_RECEIVED_MESSAGE_HOOK' constant value.
				#
				#  More info at:
				#
				#  macro plugin -> Events -> hook <hookname>
				#  https://openkore.com/wiki/macro_plugin#Automacros
				#
				#  eventMacro plugin -> SimpleHookEvent:
				#  https://openkore.com/wiki/eventMacro
				# 
				#============================================================================
				my %args = (
					msg => $json_data->{msg},
					sender => $json_data->{sender},
					senderGroup => $json_data->{senderGroup},
				);
				Plugins::callHook(WS_RECEIVED_MESSAGE_HOOK, \%args); # calls the subroutine 'ws_on_message_received'
				#============================================================================
				#============================================================================
			} else {
				#============================================================================
				#  If message starts with 'do ', a warning is printed to the console,
				#  then the command starts running.
				#============================================================================
				my %args = (
					cmd => $1,
					sender => $json_data->{sender},
					senderGroup => $json_data->{senderGroup},
				);
				Plugins::callHook(WS_RECEIVED_COMMAND_HOOK, \%args); # calls the subroutine 'ws_on_command_received'
				#============================================================================
				#============================================================================

				
				#============================================================================
				#
				#  (Will be removed)
				#
				#  A confirmation is sent back when the plugin
				#  receives a command.
				#
				#  This doesn't mean the plugins knows when the
				#  command finished running.
				#
				#  Beware of command flooding.
				#
				#============================================================================
				my $type_str = WS_TYPE_RES_CMD;
				$type_str =~ s/\Q@{[VALUE_PLACEHOLDER]}\E/$json_data->{msg}/g;
				my $res_str = WS_RES_CMD_RECV;
				$res_str =~ s/\Q@{[VALUE_PLACEHOLDER]}\E/$json_data->{msg}/g;
				my $response_json = ws_build_response_json($type_str, $res_str);
				ws_send_message($response_json);
				#============================================================================
				#============================================================================
			}
		}
	}
	$buffer = "";
}


#-----------------------------------------------------------------------------------


sub ws_heartbeat { # TODO: heartbeat implementation seems almost useless and timestamps aren't working well, needs review
	
	my $now = time;
	
	# Try to reconnect without blocking
	if (!$sock) { ws_connect_tcp(); return; }
	if ($sock && !$handshake) { ws_send_handshake(); return; }
	if ($sock && $handshake && !$connected) { ws_advance_handshake(); return; }
	
	# wscWarning("'ws_heartbeat' called.\n");
	
	# If connected, send heartbeat
	if ($connected) {
		my $elapsed_hb = $now - $last_heartbeat;
		if ($elapsed_hb > $ws_heartbeat_interval) {
			my $ping_frame = Protocol::WebSocket::Frame->new(
				type => 'ping',
				masked => 1
			);
			print $sock $ping_frame->to_bytes;
			$last_heartbeat = $now;
		} # else {
			# wscWarning("Time OK (1). Last heartbeat: $elapsed_hb\n");
		# }

		# If timed out, it's disconnected
		my $elapsed_pong = $now - $last_pong;
		if ($elapsed_pong > $ws_heartbeat_interval * 2) {
			wscWarning("Disconnected.\n");
			ws_close();
			return;
		} # else {
			# wscWarning("Time OK (2). Last pong: $elapsed_pong\n");
		# }
	}
}


#-----------------------------------------------------------------------------------


sub ws_close {
	# wscWarning("ws_close called.\n");
	eval { close $sock if $sock };
	$sock = undef;
	$frame = undef;
	$handshake = undef;
	$buffer = "";
	$connected = 0;
}


#-----------------------------------------------------------------------------------
#===================================================================================
#===================================================================================




sub ws_mapserver_dc {
	my %content = (
		ws_group_id => defined $config{ws_group} ? $config{ws_group} : -1,
	);
	my $response_json = ws_build_response_json(WS_TYPE_CLT_MSG_GROUP_DC, \%content);
	ws_send_message($response_json);
}




#===================================================================================
#  Send a message to the server.
#===================================================================================
sub ws_send_message {
	my ($msg) = @_;

	return unless $connected && $sock;

	my $to_send = Protocol::WebSocket::Frame->new(
		masked => 1  # required for clients
	);

	$to_send->append($msg);
	print $sock $to_send->to_bytes;
}
#===================================================================================
#===================================================================================




#===================================================================================
#  Standard template for messages
#===================================================================================
#
#  Use ws_build_response_json($type, $content) to build messages using the
#  following standard template:
#
#
#     my $foo = ws_build_response_json("FOO_BAR_TYPE", "Hello World!");
#     ws_send_message($foo);
#
#-----------------------------------------------------------------------------------
#
#  Output:
#
#		{
#			type: "FOO_BAR_TYPE",
#			message: {
#				ws_id: "rogue_01", # loaded from 'ws_id' in the config.txt
#				content: "Hello World!" # or any stringified object (e.g. JSON)
#			}
#		}
#
#===================================================================================
#-----------------------------------------------------------------------------------


sub ws_build_response_json {
	my ($type, $content) = @_;
	my %response = ws_build_response($type, $content);
	my $response_json = to_json(\%response, { utf8 => 1 });
	return $response_json;
}


#-----------------------------------------------------------------------------------


sub ws_build_response {
	my ($type, $content) = @_;
	my %message = ws_build_response_content($content);
	my %response = ( type => $type, message => \%message );
	return %response;
}


#-----------------------------------------------------------------------------------


sub ws_build_response_content {
	my ($content) = @_;

	
	my %message = (
		ws_id => $config{ws_id},
		ws_group => defined $config{ws_group} ? $config{ws_group} : -1,
		content => $content,
	);


	return %message;
}


#-----------------------------------------------------------------------------------
#===================================================================================
#===================================================================================




sub wscWarning {
	my ($msg) = @_;
	warning("[wsc] ".$msg);
}




sub wscMessage {
	my ($msg) = @_;
	message("[wsc] ".$msg);
}




sub wscError {
	my ($msg) = @_;
	error("[wsc] ".$msg);
}




sub unloadPlugin {
	message("\nUnloading ".PLUGIN_NAME." plugin...\n");
	Commands::unregister($pluginCmds);
	Plugins::delHooks($hooks);
	undef $pluginCmds;
}
