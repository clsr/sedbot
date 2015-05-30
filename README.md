sedbot
======

sedbot is an IRC search-replace bot written using bash and sed.

Usage: Edit the settings on top of sedbot.bash and run it under an unprivileged user.

Only the s command and g and i flags are supported. Multiple regular expressions can be used at once, delimit them with spaces in between the flags and the s next one's s command. The last one may omit the trailing / if it has no options.

Example usage in chat:

    <foo> Hello ther!
    <foo> s/ther/there
    <sedbot> <foo> Hello there!

    <foo> I'm programmign right now
    <bar> foo: s/gn/ng/
    <sedbot> <foo> I'm programming right now

    <foo> abcdefghi
    <foo> s/\(.\)./\u\1/g s/
    <sedbot> <foo> ACEGi
    <foo> s/[a-e]//g s/\(.\)\(.\)/\2\1
    <sedbot> <foo> gfhi

Note that the bot uses the standard grep (POSIX) regular expressions, i.e. use `.\+` and `\(foo\)\?` instead of `.+` and `(foo)?` as you'd do in egrep or other regex engines.
