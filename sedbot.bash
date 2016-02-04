#!/bin/bash
#sedbot: a regex IRC bot in bash and sed
#license: GNU GPL v3+


SERVER=irc.example.net # the IRC server to connect to
PORT=6667 # port to connect to
NICK=sedbot # bot's nickname
LOGIN=sedbot # bot's username
PASSWD=$ARGV1
REALNAME=sedbot # bot's name
CHANNELS=('#example') # array of channels to autojoin at start
IRC_LOG=~/sedbot.log # irc message log
ERROR_LOG=~/sedbot.err # log of errors, events and used regexps

MAX_LINE_LENGTH=400 # truncate lines to this many bytes
SLEEP_JOIN=3 # sleep after identifying before autojoining channels
SLEEP_RECONNECT=10 # sleep before reconnecting on disconnect
READ_TIMEOUT=300 # seconds before reconnect if no line is read
ACCEPT_INVITES=1 # 0 to ignore invites


###############################################################################


exec 4> >(tee -a -- "$IRC_LOG") 2> >(tee -a -- "$ERROR_LOG" >&2)

declare -A messages

connect() {
	exec 3<>"/dev/tcp/$SERVER/$PORT"
	if (($?)); then
		return $?
	fi
	sendmsg NICK "$NICK"
	if (($?)); then
		return $?
	fi
	sendmsg USER "$LOGIN 8 *" "$REALNAME"
	if (($?)); then
		return $?
	fi
	sendmsg NICKSERV "identify $PASSWD"
	if (($?)); then
		return $?
	fi
	return 0
}

#:source COMMAND a r g s :message
# 2-src, 3-cmd, 5-arg, 7-msg
message_regex='^\(:\([^ ]\+\)\ \)\?\([A-Z0-9]\+\)\( \([^:]\+\)\)\?\( \?:\([^\r\n]*\)\)\?\([\r\n]*\)\?$'

parse_source() { #rawmsg
	sed "s/$message_regex/\2/g" <<< "$1"
}

parse_command() { #rawmsg
	sed "s/$message_regex/\3/g" <<< "$1"
}

parse_args() { #rawmsg
	sed -e "s/$message_regex/\5/g" -e 's/^\s//' -e 's/\s$//' <<< "$1"
}

parse_message() { #rawmsg
	sed "s/$message_regex/\7/g" <<< "$1"
}

#nick!login@host
# 1-nick, 2-login, 3-host
user_regex='^\([^!]\+\)!\([^@]\+\)@\(.*\)$'

parse_user_nick() { # rawsource
	sed "s/$user_regex/\1/g" <<< "$1"
}

parse_user_login() { # rawsource
	sed "s/$user_regex/\2/g" <<< "$1"
}

parse_user_host() { # rawsource
	sed "s/$user_regex/\3/g" <<< "$1"
}

parse_ctcp() { # message
	ctcp="$(sed 's/^\x01\([A-Za-z]\+\)\x01$/\U\1/g' <<< "$1")"
	if [[ $ctcp != "$1" ]]; then
		sed : <<< "$ctcp"
		return 0
	fi
	return 1
}

parse_action() { # message
	cmd="$(sed 's/^\x01\([A-Za-z]\+\) \(.\+\)\x01$/\U\1/g' <<< "$1")"
	msg="$(sed 's/^\x01\([A-Za-z]\+\) \(.\+\)\x01$/\2/g' <<< "$1")"
	if [[ $cmd == 'ACTION' && -n $msg ]]; then
		sed : <<< "$msg"
		return 0
	fi
	return 1
}

parse_targeted_nick() { # message
	target="$(sed 's/^\([^ :,/]\+\)[:,]\? .\+/\1/' <<< "$1")"
	if [[ -n $target && $target != "$1" ]]; then
		sed : <<< "$target"
		return 0
	fi
	return 1
}

parse_targeted_msg() { # message
	target="$(sed 's/^[^ :,/]\+[:,]\? \(.\+\)/\1/' <<< "$1")"
	if [[ -n $target && $target != "$1" ]]; then
		sed : <<< "$target"
		return 0
	fi
	return 1
}

trimrn() { # <string
	sed -e 's/\r//g' -e 's/\n//g' -e 1q
}

indexof() { # haystack, needle
	str="$1"
	search="$2"

	i=0;
	while :; do
		if ((i >= ${#str})); then
			i=-1
			break
		fi
		if [[ ${str:$i:1} == "$search" ]]; then
			break
		fi
		((i++))
	done

	echo "$i"
}

regex() { # regex, text
	msg="$1"
	target="$2"


	#tokenize
	l=()
	pos="$(indexof "$msg" '/')"
	while ((pos >= 0)); do
		i=0
		((p=pos-i-1))
		while ((p >= 0)) && [[ ${msg:$p:1} == '\' ]]; do # count \ characters
			((i++))
			((p=pos-i-1))
		done
		if ((i%2 == 0)); then
			l+=("${msg:0:$pos}")
			((p=pos+1))
			msg="${msg:$p}"
			pos=0
		else
			((pos++))
		fi
		p="$(indexof "${msg:$pos}" '/')"
		if ((p >= 0)); then
			((pos+=p))
		else
			pos=$p
		fi
	done
	l+=("$msg")

	# l is now an array of the expr separated by unescaped /

	i=0
	regexps=()
	ok=1

	# s/expr1/repl1/opts1 s/expr2/repl2/opts2 s/expr3/repl3
	while ((i < ${#l[@]})); do
		# begins with s
		if [ "${l[$i]}" != "s" ]; then
			break
		fi
		((i++))

		# expr
		if ((i >= ${#l[@]})); then
			break
		fi
		exp="${l[$i]}"
		((i++))

		# repl
		if ((i >= ${#l[@]})); then
			break
		fi
		repl="${l[$i]}"
		((i++))

		# opts
		opts=''
		if ((i < ${#l[@]})); then
			opts="${l[$i]}"
			p=0
			while ((p < ${#opts})); do
				c="${opts:$p:1}"
				if [[ $c != 'i' && $c != 'g' ]]; then
					ok=0
					break
				fi
				((p++))
			done
			if ! ((ok)); then
				# multiple regexps per line
				if [[ ${opts:$p:1} == ' ' ]]; then
					p1=$p
					while ((p < ${#opts})); do
						if [[ ${opts:$p:1} != ' ' ]]; then
							break
						fi
						p=$((p+1))
					done
					l[$i]="${opts:$p}"
					opts="${opts:0:$p1}"
					ok=1
				else
					break
				fi
			fi
		fi

		if ((ok)); then
			regexps+=("s/$exp/$repl/$opts")
		fi
	done


	if ! ((ok)) || ((${#regexps[@]} == 0)); then
		return 1
	fi

	t="$target"
	for re in "${regexps[@]}"; do
		sed : <<< "$re" >&2
		target="$(sed -e "$re" <<< "$target")"
	done
	target="$(trimrn <<< "$target")"
	if [[ $target != "$t" ]]; then
		if [[ -n $target ]]; then
			trimrn <<< "$target"
			return 0
		fi
	fi
	return 1
}

sendmsg() { # command, args, message
	if (($# > 0)); then
		cmd="$(sed -e 's/\(.*\)/\U\1/g' <<< "$1" | trimrn)"
		if (($# > 1)); then
			args="$(trimrn <<< "$2")"
			if (($# > 2)); then
				msg="$(trimrn <<< "$3")"
				if [[ -n $args ]]; then
					line="$cmd $args :$msg"
				else
					line="$cmd :$msg"
				fi
			else
				line="$cmd $args"
			fi
		else
			line="$cmd"
		fi
	fi
	if [[ -n $line ]]; then
		line="$(trimrn <<< "$line" | sed 's/^\(.\{,'"$MAX_LINE_LENGTH"'\}\).*/\1/')"
		echo "$(date +%s.%N) >>> $line" >&4
		sed : <<< "$line" >&3
		if (($? == 0)); then
			return 0
		else
			return $?
		fi
	else
		echo 'invalid usage of message' >&2
		exit 1
	fi
	return 1
}

readmsg() {
	IFS= read -r -u 3 -t "$READ_TIMEOUT" line
	success=$?
	echo "$(date +%s.%N) <<< $line" >&4
	sed : <<< "$line"
	return $success
}

readloop() {
	while :; do
		line="$(readmsg)"
		if (($?)); then
			echo 'disconnected from server' >&2
			break
		fi
		cmd="$(parse_command "$line")"

		case $cmd in
			PING)
				sendmsg PONG "$(parse_args "$line")" "$(parse_message "$line")"
				;;

			INVITE)
				args="$(parse_args "$line")"
				who="$(sed   's/\(\([^ ]*\)\( \|$\)\)\{1\}.*/\2/' <<< "$args")"
				where="$(sed 's/\(\([^ ]*\)\( \|$\)\)\{2\}.*/\2/' <<< "$args")"
				if [[ $where == "$who" || -z $where ]]; then
					who="$args"
					where="$(parse_message "$line")"
				fi
				if [[ $who == "$NICK" && -n $where && $ACCEPT_INVITES != 0 ]]; then
					echo "invited to $where" >&2
					sendmsg JOIN "$where"
					CHANNELS+=("$where")
				fi
				;;

			KICK)
				args="$(parse_args "$line")"
				where="$(sed 's/\(\([^ ]*\)\( \|$\)\)\{1\}.*/\2/' <<< "$args")"
				who="$(sed   's/\(\([^ ]*\)\( \|$\)\)\{2\}.*/\2/' <<< "$args")"
				if [[ $who == "$NICK" && -n $where ]]; then #TODO: got "too many arguments" error when others are kicked; is it fixed now?
					echo "kicked from $where" >&2
					i=0
					while ((i < ${#CHANNELS})); do
						if [[ ${CHANNELS[$i]} == "$where" ]]; then
							unset -v "CHANNELS[$i]"
						else
							((i++))
						fi
					done
				fi
				;;

			433)
				echo "nick $NICK is already taken" >&2
				exit 1
				;;

			PRIVMSG)
				where="$(parse_args "$line")"
				user="$(parse_source "$line")"
				nick="$(parse_user_nick "$user")"
				msg="$(parse_message "$line")"
				if [[ $where == "$NICK" ]]; then
					where="$nick"
					ctcp="$(parse_ctcp "$msg")"
					if (($? == 0)); then
						if [[ $ctcp == VERSION ]]; then
							version="$(sed --version 2>&1 | trimrn)" # some seds don't have --version, have to fix?
							sendmsg NOTICE "$where" "$(sed 's/^.*$/\x01&\x01/' <<< "$ctcp $version")"
							continue
						fi
					fi
				fi
				targetednick="$(parse_targeted_nick "$msg")"
				istargeted=$?
				targetedkey="$where $targetednick"
				origmsg="$msg"
				origkey="$where $nick"
				if [[ $istargeted == 0 && -n "${messages[$targetedkey]}" ]]; then
					nick="$targetednick"
					msg="$(parse_targeted_msg "$msg")"
				fi
				key="$where $nick"
				target="${messages[$key]}"
				action="$(parse_action "$target")"
				if (($? == 0)); then
					target="$action"
					fromnick="$(printf "\\x02* %s\\x02" "$nick")"
				else
					fromnick="<$nick>"
				fi
				regexed="$(regex "$msg" "$target")"
				if (($? == 0)); then
					sendmsg PRIVMSG "$where" "$fromnick $regexed"
				elif [[ $istargeted != 0 ]]; then
					messages[$key]="$msg"
				else
					messages[$origkey]="$origmsg"
				fi
				;;
		esac
	done
}

main() {
	while :; do
		if connect; then
			sleep "$SLEEP_JOIN"
			for ch in "${CHANNELS[@]}"; do
				sendmsg JOIN "$ch"
			done
			readloop
		fi
		echo 'reconnecting in 10 seconds...' >&2
		sleep "$SLEEP_RECONNECT"
	done
}

main
