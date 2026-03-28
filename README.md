# wsCommands 2 Plugin

##  WebSocket client for sending and receiving OpenKore commands.

---

### [wsCommands Server](https://github.com/locvtvs/wsCommands-server) is required.

> Compatible with server version 2.x

---


### Install all dependencies:
```console
cpanm IO::Socket::INET Protocol::WebSocket::Handshake::Client Protocol::WebSocket::Frame JSON
```

---

### config.txt
> Do NOT use spaces or quotation marks in *ws_id* or *ws_group*.
> Note: "group" here is NOT about in-game party.

```text
ws_id <client_id>
ws_group <group_id>
ws_url <server_url (default: ws://localhost:3000)>
```

##### Needs review
```text
ws_hb_interval <seconds (default: 3)>
```

---

### Commands:

#### Sending console commands and messages:
##### To a specific client:
```console
ws sendcmd <target_id> <console command>
```
```console
ws sendmsg <target_id> <message>
```
##### To all clients connected to the WebSocket server:
```console
ws sendcmd <-a|-all> <console command>
```
```console
ws sendmsg <-a|-all> <message>
```
##### To all clients (except myself):
```console
ws sendcmd <-o|--others> <console command>
```
```console
ws sendmsg <-o|--others> <message>
```
##### To server (message only):
```console
ws sendmsg <-sv|--server> <message>
```
##### To myself:
```console
ws sendcmd <-ms|--myself> <console command>
```
```console
ws sendmsg <-ms|--myself> <message>
```
##### To all clients in a specific group:
> Note: "group" here is NOT about in-game party.

```console
ws sendcmd <-g|--group> <group_id> <console command>
```
```console
ws sendmsg <-g|--group> <group_id> <message>
```
##### To all clients in a specific group (except to myself):
> Note: "group" here is NOT about in-game party.

```console
ws sendcmd <-ge|--groupexcept> <group_id> <console command>
```
```console
ws sendmsg <-ge|--groupexcept> <group_id> <message>
```
##### To all clients in your group:
> Note: "group" here is NOT about in-game party.

```console
ws sendcmd <-mg|--mygroup> <console command>
```
```console
ws sendmsg <-mg|--mygroup> <message>
```

#### Emitting server events:
```console
ws emitsv "event name" <stringified data>
```

#### Debug commands:
##### Run specific subroutines:
```console
ws ws_mapserver_dc
```
```console
ws ws_close
```
```console
ws ws_start3
```
```console
ws ws_tick
```

---

### Hooks:

#### On Command Received

```text
wsCommands/command_received
```

##### Args:
```perl
cmd, # command string without 'do'
sender, # client id
senderGroup # group id
```

#### On Message Received

```text
wsCommands/message_received
```

##### Args:
```perl
msg, # message string
sender, # client id
senderGroup # group id
```

---

# Notes:

### The client will send a message to all clients in the same group when it disconnects from the Map Server.
> Note: "group" here is NOT about in-game party.

#### Message template:

```text
A client has been disconnected from Map Server: 'sender_id' (group: 'sender_group_id')
```
