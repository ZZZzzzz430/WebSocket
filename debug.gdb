set pagination off
set confirm off
set print pretty on
set breakpoint pending on
set print thread-events off
handle SIGPIPE nostop noprint pass

directory .
directory src
directory include

define hook-stop
    printf "\n========== GDB STOP ==========\n"
    info threads
    frame
    bt 6
    printf "==============================\n"
end
##
break Channel::enableReading
break Channel::update
break Channel::handleEventWithGuard
break TcpConnection::handleRead

run
