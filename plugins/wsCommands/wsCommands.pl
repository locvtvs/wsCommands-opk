package wsCommands;




#   __________________          _-_
#   \__by_locvtvs____|)____.---'---`---.____
#                ||    \----._________.----/
#                ||     / ,'   `---'
#             ___||_,--'  -._ 
#            /___   1.0.0  ||(-
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
use Errno qw(EAGAIN EINPROGRESS);
use JSON;
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
#  This plugin act as a WebSocket client,
#  so it need to check if the connection is still alive often.
#
#  When the plugin sends a ping, your WS server must response a pong (opcode 10).
#
#
#  On NodeJs 'ws' library, pong is sent automatic (usually).
#
#  $ws_heartbeat_interval will be replaced by 'ws_hb_interval' from config.txt
#===================================================================================
my $last_pong = time;
my $last_heartbeat = time;
my $ws_heartbeat_interval = 3; # seconds
#===================================================================================
#===================================================================================




#===================================================================================
#  Useful constants
#===================================================================================
use constant {
		PLUGIN_NAME => "wsCommands", # it's for log messages, usually
		PLUGIN_VERSION => "1.0.0",
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
		WS_TYPE_HS_DONE => "HANDSHAKE_DONE",
		WS_TYPE_CLT_CLT => "CLT_TO_CLT_CMD",
		WS_TYPE_CLT_ALL => "CLT_TO_ALL_CMD",
		WS_TYPE_CLT_OTHERS => "CLT_TO_OTHERS_CMD",
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
my $pluginCmds	=	Commands::register	(
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
my $hooks = Plugins::addHooks	(
										['start3', \&ws_start3],
										['mainLoop_post', \&ws_tick],
								);
#===================================================================================
#===================================================================================




#===================================================================================
#  In case the plugin is reloaded, $url will be formatted again.
#===================================================================================
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
	} else {
		wscError("test");
	}


	if ($sub_cmd eq "send") {
			#=======================================================================================
			#  ws send "target_id" <console command>
			#=======================================================================================
			if ($sub_args =~ /"([^"]+)"\s+(.*)/) {

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
			#  ws send -a <console command>
			#  ws send --all <console command>
			#=======================================================================================
			elsif ($sub_args =~ /(-a|--all)\s+(.*)/) {

					my %content = (
							cmd => $2,
					);

					my $response_json = ws_build_response_json(WS_TYPE_CLT_ALL, \%content);
					ws_send_message($response_json);

			}
			#=======================================================================================
			#=======================================================================================


			#=======================================================================================
			#  ws send -o <console command>
			#  ws send --others <console command>
			#=======================================================================================
			elsif ($sub_args =~ /(-o|--others)\s+(.*)/) {

					my %content = (
							cmd => $2,
					);

					my $response_json = ws_build_response_json(WS_TYPE_CLT_OTHERS, \%content);
					ws_send_message($response_json);

			}
			#=======================================================================================
			#=======================================================================================
			else {
					wscError	("Invalid command arguments.\n".
														"Use:\n". 
														"    " . CMD_MAIN . " send \"target_id\" <console command>\n".
														"  " . "or:\n".
														"    " . CMD_MAIN . " send <-o|--others> <console command>\n"
										);
			}
			#=======================================================================================
			#=======================================================================================
	}
	#===========================================================================================
	#===========================================================================================


	#===========================================================================================
	#  ws about
	#===========================================================================================
	elsif ($sub_cmd eq "help") {

			wscWarning	("wsCommands ".PLUGIN_VERSION." by locvtvs - https://github.com/locvtvs\n".
														"-- Commands:\n".
														"       " . CMD_MAIN . " send \"target_id\" <console command>\n".
														"       " . CMD_MAIN . " send <-a|--all> <console command>\n".
														"       " . CMD_MAIN . " send <-o|--others> <console command>\n".
														"       " . CMD_MAIN . " help\n"
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
		#===================================================================================
		#  ws_tick() will only run after the config.txt is loaded, since the plugin needs
		#  the value of 'ws_url' from that file in order to connect to the server.
		#  Therefore, we need wait for the 'start3' hook.
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
		#  control/config.txt must be already loaded for this to occur ('start3' hook).
		#
		#  More info at:
		#  https://openkore.com/wiki/hooks#start3
		#  https://openkore.com/wiki/hooks#mainLoop_post
		#===================================================================================
		if ($start3_finished) { # only if the start3 hook has already ben called
				ws_connect_tcp();
				ws_send_handshake();
				ws_advance_handshake();
				ws_process_frames();
				ws_heartbeat();
		}
		#===================================================================================
		#===================================================================================
}



#===================================================================================
#  WebSocket client life-cycle that doesn't block Openkore mainLoop.
#===================================================================================
#-----------------------------------------------------------------------------------


sub ws_connect_tcp {
		return if $sock; # already connected or trying

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
		return unless $sock && !$handshake;

		$handshake = Protocol::WebSocket::Handshake::Client->new(url => $url);
		print $sock $handshake->to_string;
}


#-----------------------------------------------------------------------------------


sub ws_advance_handshake {
		return unless $sock && $handshake && !$connected;


		my $read = "";
		my $n = sysread($sock, $read, 4096);
		return unless $n;


		$buffer .= $read;

		unless ($handshake->is_done) {
				$handshake->parse($buffer);
				if ($handshake->is_done) {
						$frame = Protocol::WebSocket::Frame->new;
						$connected = 1;
						$last_pong = time;
						wscWarning("Handshake completed!\n");
						$warned_disconnected = 0;


						#==================================================================
						#  Sends the first response to the server.
						#  Check the constants section at the beginning of this script.
						#==================================================================
						my $response_json = ws_build_response_json(WS_TYPE_HS_DONE, "");
						ws_send_message($response_json);
						#==================================================================
						#==================================================================
				}
		}
}


#-----------------------------------------------------------------------------------


sub ws_process_frames {
		return unless $sock;


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
		if (!defined $n && $! != EAGAIN && $! != EINPROGRESS) {
				wscWarning("Read error: $!\n");
				ws_close();
				return;
		}


		$buffer .= $read if $n;
		return unless $frame;  # before handshake


		$frame->append($buffer);
		for (my $msg = $frame->next; defined $msg; $msg = $frame->next) {

				my $opcode = $frame->opcode;
				if    ($opcode == 10) {
						$last_pong = time;
						# wscWarning("Pong received\n");
				}
				elsif ($opcode == 9)  { wscWarning("Ping received\n"); }
				elsif ($opcode == 8)  { wscWarning("Close received\n"); ws_close(); }
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
						unless ($msg =~ /^do\s+(.*)/) {
								#========================================================================
								#  If it doesn't start with 'do ', the message will only be
								#  printed to the console.
								#
								#  It's useful for automacros that
								#  uses 'console /<regexp>/' condition.
								#
								#  More info at:
								#  https://openkore.com/wiki/macro_plugin#Automacros
								#========================================================================
								wscWarning("Message received: $msg\n"); # not a command
								#========================================================================
								#========================================================================
						} else {
								#========================================================================
								#  If message starts with 'do ', a warning is printed to the console,
								#  then the command starts running.
								#========================================================================
								wscWarning("Running command: $1\n");
								Commands::run($1);
								#========================================================================
								#========================================================================

								
								#========================================================================
								#  A confirmation is sent back when the plugin
								#  receives a command.
								#
								#  This doesn't mean the plugins knows when the
								#  command finished running.
								#
								#  Beware of command flooding.
								#========================================================================
								my $type_str = WS_TYPE_RES_CMD;
								$type_str =~ s/\Q@{[VALUE_PLACEHOLDER]}\E/$msg/g;


								my $res_str = WS_RES_CMD_RECV;
								$res_str =~ s/\Q@{[VALUE_PLACEHOLDER]}\E/$msg/g;

								my $response_json = ws_build_response_json($type_str, $res_str);
								ws_send_message($response_json);
								#========================================================================
								#========================================================================
						}
				}

		}
		$buffer = "";
}


#-----------------------------------------------------------------------------------


sub ws_heartbeat {
		my $now = time;

		# Try to reconnect without blocking
		if (!$sock) {
				ws_connect_tcp();
				return;
		}

		if ($sock && !$handshake) {
				ws_send_handshake();
				return;
		}

		if ($sock && $handshake && !$connected) {
				ws_advance_handshake();
				return;
		}

		# If connected, send heartbeat
		if ($connected) {
				if ($now - $last_heartbeat > $ws_heartbeat_interval) {
						my $ping_frame = Protocol::WebSocket::Frame->new(
								type => 'ping',
								masked => 1
						);
						print $sock $ping_frame->to_bytes;
						$last_heartbeat = $now;
				}

				# If timed out, it's disconnected
				if ($now - $last_pong > $ws_heartbeat_interval * 2) {
						wscWarning("Disconnected.\n");
						ws_close();
						return;
				}
		}
}


#-----------------------------------------------------------------------------------


sub ws_close {
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




#===================================================================================
#  Sends a message to the server.
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
		undef $pluginCmds;
}
