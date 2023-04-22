hammerdb>print script
#!/usr/local/bin/tclsh8.6
#EDITABLE OPTIONS##################################################
set library mysqltcl ;# MySQL Library
global mysqlstatus
set total_iterations 60000000 ;# Number of transactions before logging off
set RAISEERROR "false" ;# Exit script on MySQL error (true or false)
set KEYANDTHINK "false" ;# Time for user thinking and keying (true or false)
set rampup 2;  # Rampup time in minutes before first Transaction Count is taken
set duration 30;  # Duration in minutes before second Transaction Count is taken
set mode "Local" ;# HammerDB operational mode
set host "x.x.x.x" ;# Address of the server hosting MySQL
set port "3306" ;# Port of the MySQL Server, defaults to 3306
set socket "/tmp/mysql.sock" ;# MySQL Socket for local connections
set ssl_options { -ssl false } ;# MySQL SSL/TLS options
set user "hammerdb" ;# MySQL user
set password "xxx" ;# Password for the MySQL user
set db "hammerdb" ;# Database containing the TPC Schema
set prepare "false" ;# Use prepared statements
set allwarehouses "true";# Use all warehouses to increase I/O
            #EDITABLE OPTIONS##################################################
#LOAD LIBRARIES AND MODULES
if [catch {package require $library} message] { error "Failed to load $library - $message" }
if [catch {::tcl::tm::path add modules} ] { error "Failed to find modules directory" }
if [catch {package require tpcccommon} ] { error "Failed to load tpcc common functions" } else { namespace import tpcccommon::* }

if { [ chk_thread ] eq "FALSE" } {
    error "MYSQL Timed Script must be run in Thread Enabled Interpreter"
}
proc chk_socket { host socket } {
    if { ![string match windows $::tcl_platform(platform)] && ($host eq "127.0.0.1" || [ string tolower $host ] eq "localhost") && [ string tolower $socket ] != "null" } {
        return "TRUE"
    } else {
        return "FALSE"
    }
}

proc ConnectToMySQL { host port socket ssl_options user password db } {
    global mysqlstatus
    #ssl_options is variable length so build a connectstring
    if { [ chk_socket $host $socket ] eq "TRUE" } {
    	set use_socket "true"
    	append connectstring " -socket $socket"
    } else {
        set use_socket "false"
        append connectstring " -host $host -port $port"
	}
    foreach key [ dict keys $ssl_options ] {
        append connectstring " $key [ dict get $ssl_options $key ] "
    }
    append connectstring " -user $user -password $password"
    set login_command "mysqlconnect [ dict get $connectstring ]"
    #eval the login command
    if [catch {set mysql_handler [eval $login_command]}] {
        if $use_socket {
            puts "the local socket connection to $socket could not be established"
        } else {
            puts "the tcp connection to $host:$port could not be established"
        }
        set connected "false"
    } else {
        set connected "true"
    }
    if {$connected} {
        mysqluse $mysql_handler $db
        mysql::autocommit $mysql_handler 0
        catch {set ssl_status [ mysql::sel $mysql_handler "show session status like 'ssl_cipher'" -list ]}
        if { [ info exists ssl_status ] } {
            puts [ join $ssl_status ]
        }
        return $mysql_handler
    } else {
        error $mysqlstatus(message)
        return
    }
}

set rema [ lassign [ findvuposition ] myposition totalvirtualusers ]
switch $myposition {
    1 {
        if { $mode eq "Local" || $mode eq "Primary" } {
	        set mysql_handler [ ConnectToMySQL $host $port $socket $ssl_options $user $password $db ]
            mysql::autocommit $mysql_handler 1
            set ramptime 0
            puts "Beginning rampup time of $rampup minutes"
            set rampup [ expr $rampup*60000 ]
            while {$ramptime != $rampup} {
                if { [ tsv::get application abort ] } { break } else { after 6000 }
                set ramptime [ expr $ramptime+6000 ]
                if { ![ expr {$ramptime % 60000} ] } {
                    puts "Rampup [ expr $ramptime / 60000 ] minutes complete ..."
                }
            }
            if { [ tsv::get application abort ] } { break }
            puts "Rampup complete, Taking start Transaction Count."
            if {[catch {set handler_stat [ list [ mysql::sel $mysql_handler "show global status where Variable_name = 'Com_commit' or Variable_name =  'Com_rollback'" -list ] ]}]} {
                puts stderr {error, failed to query transaction statistics}
                return
            } else {
                regexp {\{\{Com_commit\ ([0-9]+)\}\ \{Com_rollback\ ([0-9]+)\}\}} $handler_stat all com_comm com_roll
                set start_trans [ expr $com_comm + $com_roll ]
            }
            if {[catch {set start_nopm [ list [ mysql::sel $mysql_handler "select sum(d_next_o_id) from district" -list ] ]}]} {
                puts stderr {error, failed to query district table}
                return
            }
            puts "Timing test period of $duration in minutes"
            set testtime 0
            set durmin $duration
            set duration [ expr $duration*60000 ]
            while {$testtime != $duration} {
                if { [ tsv::get application abort ] } { break } else { after 6000 }
                set testtime [ expr $testtime+6000 ]
                if { ![ expr {$testtime % 60000} ] } {
                    puts -nonewline  "[ expr $testtime / 60000 ]  ...,"
                }
            }
            if { [ tsv::get application abort ] } { break }
            puts "Test complete, Taking end Transaction Count."
            if {[catch {set handler_stat [ list [ mysql::sel $mysql_handler "show global status where Variable_name = 'Com_commit' or Variable_name =  'Com_rollback'" -list ] ]}]} {
                puts stderr {error, failed to query transaction statistics}
                return
            } else {
                regexp {\{\{Com_commit\ ([0-9]+)\}\ \{Com_rollback\ ([0-9]+)\}\}} $handler_stat all com_comm com_roll
                set end_trans [ expr $com_comm + $com_roll ]
            }
            if {[catch {set end_nopm [ list [ mysql::sel $mysql_handler "select sum(d_next_o_id) from district" -list ] ]}]} {
                puts stderr {error, failed to query district table}
                return
            }
            set tpm [ expr {($end_trans - $start_trans)/$durmin} ]
            set nopm [ expr {($end_nopm - $start_nopm)/$durmin} ]
            puts "[ expr $totalvirtualusers - 1 ] Active Virtual Users configured"
            puts [ testresult $nopm $tpm MySQL ]
            tsv::set application abort 1
            if { $mode eq "Primary" } { eval [subst {thread::send -async $MASTER { remote_command ed_kill_vusers }}] }
            catch { mysqlclose $mysql_handler }
        } else {
            puts "Operating in Replica Mode, No Snapshots taken..."
        }
    }
    default {
        #TIMESTAMP
        proc gettimestamp { } {
            set tstamp [ clock format [ clock seconds ] -format %Y%m%d%H%M%S ]
            return $tstamp
        }
        #NEW ORDER
        proc neword { mysql_handler no_w_id w_id_input prepare RAISEERROR } {
            global mysqlstatus
            #open new order cursor
            #2.4.1.2 select district id randomly from home warehouse where d_w_id = d_id
            set no_d_id [ RandomNumber 1 10 ]
            #2.4.1.2 Customer id randomly selected where c_d_id = d_id and c_w_id = w_id
            set no_c_id [ RandomNumber 1 3000 ]
            #2.4.1.3 Items in the order randomly selected from 5 to 15
            set ol_cnt [ RandomNumber 5 15 ]
            #2.4.1.6 order entry date O_ENTRY_D generated by SUT
            set date [ gettimestamp ]
            if {$prepare} {
                catch {mysqlexec $mysql_handler "set @no_w_id=$no_w_id,@w_id_input=$w_id_input,@no_d_id=$no_d_id,@no_c_id=$no_c_id,@ol_cnt=$ol_cnt,@next_o_id=0,@date=str_to_date($date,'%Y%m%d%H%i%s')"}
                catch {mysqlexec $mysql_handler "execute neword_st using @no_w_id,@w_id_input,@no_d_id,@no_c_id,@ol_cnt,@next_o_id,@date"}
            } else {
                mysqlexec $mysql_handler "set @next_o_id = 0"
                catch { mysqlexec $mysql_handler "CALL NEWORD($no_w_id,$w_id_input,$no_d_id,$no_c_id,$ol_cnt,@disc,@last,@credit,@dtax,@wtax,@next_o_id,str_to_date($date,'%Y%m%d%H%i%s'))" }
            }
            if { $mysqlstatus(code)  } {
                if { $RAISEERROR } {
                    error "New Order : $mysqlstatus(message)"
                } else { puts $mysqlstatus(message)
                }
            } else {
                catch {mysql::sel $mysql_handler "select @disc,@last,@credit,@dtax,@wtax,@next_o_id" -list}
            }
        }
        #PAYMENT
        proc payment { mysql_handler p_w_id w_id_input prepare RAISEERROR } {
            global mysqlstatus
            #2.5.1.1 The home warehouse id remains the same for each terminal
            #2.5.1.1 select district id randomly from home warehouse where d_w_id = d_id
            set p_d_id [ RandomNumber 1 10 ]
            #2.5.1.2 customer selected 60% of time by name and 40% of time by number
            set x [ RandomNumber 1 100 ]
            set y [ RandomNumber 1 100 ]
            if { $x <= 85 } {
                set p_c_d_id $p_d_id
                set p_c_w_id $p_w_id
            } else {
                #use a remote warehouse
                set p_c_d_id [ RandomNumber 1 10 ]
                set p_c_w_id [ RandomNumber 1 $w_id_input ]
                while { ($p_c_w_id == $p_w_id) && ($w_id_input != 1) } {
                    set p_c_w_id [ RandomNumber 1  $w_id_input ]
                }
            }
            set nrnd [ NURand 255 0 999 123 ]
            set name [ randname $nrnd ]
            set p_c_id [ RandomNumber 1 3000 ]
            if { $y <= 60 } {
                #use customer name
                #C_LAST is generated
                set byname 1
            } else {
                #use customer number
                set byname 0
                set name {}
            }
            #2.5.1.3 random amount from 1 to 5000
            set p_h_amount [ RandomNumber 1 5000 ]
            #2.5.1.4 date selected from SUT
            set h_date [ gettimestamp ]
            #2.5.2.1 Payment Transaction
            if {$prepare} {
                catch {mysqlexec $mysql_handler "set @p_w_id=$p_w_id,@p_d_id=$p_d_id,@p_c_w_id=$p_c_w_id,@p_c_d_id=$p_c_d_id,@p_c_id=$p_c_id,@byname=$byname,@p_h_amount=$p_h_amount,@p_c_last='$name',@p_c_credit=0,@p_c_balance=0,@h_date=str_to_date($h_date,'%Y%m%d%H%i%s')"}
                catch { mysqlexec $mysql_handler "execute payment_st using @p_w_id,@p_d_id,@p_c_w_id,@p_c_d_id,@p_c_id,@byname,@p_h_amount,@p_c_last,@p_c_credit,@p_c_balance,@h_date"}
            } else {
                mysqlexec $mysql_handler "set @p_c_id = $p_c_id, @p_c_last = '$name', @p_c_credit = 0, @p_c_balance = 0"
                catch { mysqlexec $mysql_handler "CALL PAYMENT($p_w_id,$p_d_id,$p_c_w_id,$p_c_d_id,@p_c_id,$byname,$p_h_amount,@p_c_last,@p_w_street_1,@p_w_street_2,@p_w_city,@p_w_state,@p_w_zip,@p_d_street_1,@p_d_street_2,@p_d_city,@p_d_state,@p_d_zip,@p_c_first,@p_c_middle,@p_c_street_1,@p_c_street_2,@p_c_city,@p_c_state,@p_c_zip,@p_c_phone,@p_c_since,@p_c_credit,@p_c_credit_lim,@p_c_discount,@p_c_balance,@p_c_data,str_to_date($h_date,'%Y%m%d%H%i%s'))"}
            }
            if { $mysqlstatus(code) } {
                if { $RAISEERROR } {
                    error "Payment : $mysqlstatus(message)"
                } else { puts $mysqlstatus(message)
                }
            } else {
                catch {mysql::sel $mysql_handler "select @p_c_id,@p_c_last,@p_w_street_1,@p_w_street_2,@p_w_city,@p_w_state,@p_w_zip,@p_d_street_1,@p_d_street_2,@p_d_city,@p_d_state,@p_d_zip,@p_c_first,@p_c_middle,@p_c_street_1,@p_c_street_2,@p_c_city,@p_c_state,@p_c_zip,@p_c_phone,@p_c_since,@p_c_credit,@p_c_credit_lim,@p_c_discount,@p_c_balance,@p_c_data" -list}
            }
        }
        #ORDER_STATUS
        proc ostat { mysql_handler w_id prepare RAISEERROR } {
            global mysqlstatus
            #2.5.1.1 select district id randomly from home warehouse where d_w_id = d_id
            set d_id [ RandomNumber 1 10 ]
            set nrnd [ NURand 255 0 999 123 ]
            set name [ randname $nrnd ]
            set c_id [ RandomNumber 1 3000 ]
            set y [ RandomNumber 1 100 ]
            if { $y <= 60 } {
                set byname 1
            } else {
                set byname 0
                set name {}
            }
            if {$prepare} {
                catch {mysqlexec $mysql_handler "set @os_w_id=$w_id,@dos_d_id=$d_id,@os_c_id=$c_id,@byname=$byname,@os_c_last='$name'"}
                catch {mysqlexec $mysql_handler "execute ostat_st using @os_w_id,@dos_d_id,@os_c_id,@byname,@os_c_last"}
            } else {
                mysqlexec $mysql_handler "set @os_c_id = $c_id, @os_c_last = '$name'"
                catch { mysqlexec $mysql_handler "CALL OSTAT($w_id,$d_id,@os_c_id,$byname,@os_c_last,@os_c_first,@os_c_middle,@os_c_balance,@os_o_id,@os_entdate,@os_o_carrier_id)"}
            }
            if { $mysqlstatus(code) } {
                if { $RAISEERROR } {
                    error "Order Status : $mysqlstatus(message)"
                } else { puts $mysqlstatus(message)
                }
            } else {
                catch {mysql::sel $mysql_handler "select @os_c_id,@os_c_last,@os_c_first,@os_c_middle,@os_c_balance,@os_o_id,@os_entdate,@os_o_carrier_id" -list}
            }
        }
        #DELIVERY
        proc delivery { mysql_handler w_id prepare RAISEERROR } {
            global mysqlstatus
            set carrier_id [ RandomNumber 1 10 ]
            set date [ gettimestamp ]
            if {$prepare} {
                catch {mysqlexec $mysql_handler "set @d_w_id=$w_id,@d_o_carrier_id=$carrier_id,@timestamp=str_to_date($date,'%Y%m%d%H%i%s')"}
                catch {mysqlexec $mysql_handler "execute delivery_st using @d_w_id,@d_o_carrier_id,@timestamp"}
            } else {
                catch { mysqlexec $mysql_handler "CALL DELIVERY($w_id,$carrier_id,str_to_date($date,'%Y%m%d%H%i%s'))"}
            }
            if { $mysqlstatus(code) } {
                if { $RAISEERROR } {
                    error "Delivery : $mysqlstatus(message)"
                } else { puts $mysqlstatus(message)
                }
            } else {
                ;
            }
        }
        #STOCK LEVEL
        proc slev { mysql_handler w_id stock_level_d_id prepare RAISEERROR } {
            global mysqlstatus
            set threshold [ RandomNumber 10 20 ]
            if {$prepare} {
                catch {mysqlexec $mysql_handler "set @st_w_id=$w_id,@st_d_id=$stock_level_d_id,@threshold=$threshold"}
                catch {mysqlexec $mysql_handler "execute slev_st using @st_w_id,@st_d_id,@threshold"}
            } else {
                catch {mysqlexec $mysql_handler "CALL SLEV($w_id,$stock_level_d_id,$threshold,@stock_count)"}
            }
            if { $mysqlstatus(code) } {
                if { $RAISEERROR } {
                    error "Stock Level : $mysqlstatus(message)"
                } else { puts $mysqlstatus(message)
                }
            } else {
                catch {mysql::sel $mysql_handler "select @stock_count" -list}
            }
        }

        proc prep_statement { mysql_handler statement_st } {
            switch $statement_st {
                slev_st {
                    mysqlexec $mysql_handler "prepare slev_st from 'CALL SLEV(?,?,?,@stock_count)'"
                }
                delivery_st {
                    mysqlexec $mysql_handler "prepare delivery_st from 'CALL DELIVERY(?,?,?)'"
                }
                ostat_st {
                    mysqlexec $mysql_handler "prepare ostat_st from 'CALL OSTAT(?,?,?,?,?,@os_c_first,@os_c_middle,@os_c_balance,@os_o_id,@os_entdate,@os_o_carrier_id)'"
                }
                payment_st {
                    mysqlexec $mysql_handler "prepare payment_st from 'CALL PAYMENT(?,?,?,?,?,?,?,?,@p_w_street_1,@p_w_street_2,@p_w_city,@p_w_state,@p_w_zip,@p_d_street_1,@p_d_street_2,@p_d_city,@p_d_state,@p_d_zip,@p_c_first,@p_c_middle,@p_c_street_1,@p_c_street_2,@p_c_city,@p_c_state,@p_c_zip,@p_c_phone,@p_c_since,?,@p_c_credit_lim,@p_c_discount,?,@p_c_data,?)'"
                }
                neword_st {
                    mysqlexec $mysql_handler "prepare neword_st from 'CALL NEWORD(?,?,?,?,?,@disc,@last,@credit,@dtax,@wtax,?,?)'"
                }
            }
        }
        #RUN TPC-C
        set mysql_handler [ ConnectToMySQL $host $port $socket $ssl_options $user $password $db ]
        if {$prepare} {
            foreach st {neword_st payment_st delivery_st slev_st ostat_st} { set $st [ prep_statement $mysql_handler $st ] }
        }
        set w_id_input [ list [ mysql::sel $mysql_handler "select max(w_id) from warehouse" -list ] ]
        #2.4.1.1 does not apply when allwarehouses is true
                if { $allwarehouses == "true" } {
                    set loadUserCount [expr $totalvirtualusers - 1]
                    set myWarehouses {}
                    set addMore 0
                    set whRequiredCount [expr ceil(double($w_id_input)/double($loadUserCount))]
                    while {$addMore >= 0} {
                        set wh [expr ((($myposition - 2) + ($addMore * $loadUserCount))%$w_id_input)+1]
                        if {$addMore >= $whRequiredCount} {
                            set addMore -1
                        } else {
                            puts "VU $myposition : Assigning WID=$wh based on VU count $loadUserCount, Warehouses = $w_id_input ([expr $addMore + 1] out of [ expr int($whRequiredCount)])"
                            lappend myWarehouses $wh
                            set addMore [expr $addMore + 1]
                        }
                    }
                    set myWhCount [llength $myWarehouses]
                }
            #2.4.1.1 set warehouse_id stays constant for a given terminal
        set w_id  [ RandomNumber 1 $w_id_input ]
        set d_id_input [ list [ mysql::sel $mysql_handler "select max(d_id) from district" -list ] ]
        set stock_level_d_id  [ RandomNumber 1 $d_id_input ]
        puts "Processing $total_iterations transactions with output suppressed..."
        set abchk 1; set abchk_mx 1024; set hi_t [ expr {pow([ lindex [ time {if {  [ tsv::get application abort ]  } { break }} ] 0 ],2)}]
        for {set it 0} {$it < $total_iterations} {incr it} {
            if { [expr {$it % $abchk}] eq 0 } { if { [ time {if {  [ tsv::get application abort ]  } { break }} ] > $hi_t }  {  set  abchk [ expr {min(($abchk * 2), $abchk_mx)}]; set hi_t [ expr {$hi_t * 2} ] } }
            if { $allwarehouses == "true" } {
                    set w_id [lindex $myWarehouses [expr [RandomNumber 1 $myWhCount] -1]]
                }
            set choice [ RandomNumber 1 23 ]
            if {$choice <= 10} {
                if { $KEYANDTHINK } { keytime 18 }
                neword $mysql_handler $w_id $w_id_input $prepare $RAISEERROR
                if { $KEYANDTHINK } { thinktime 12 }
            } elseif {$choice <= 20} {
                if { $KEYANDTHINK } { keytime 3 }
                payment $mysql_handler $w_id $w_id_input $prepare $RAISEERROR
                if { $KEYANDTHINK } { thinktime 12 }
            } elseif {$choice <= 21} {
                if { $KEYANDTHINK } { keytime 2 }
                delivery $mysql_handler $w_id $prepare $RAISEERROR
                if { $KEYANDTHINK } { thinktime 10 }
            } elseif {$choice <= 22} {
                if { $KEYANDTHINK } { keytime 2 }
                slev $mysql_handler $w_id $stock_level_d_id $prepare $RAISEERROR
                if { $KEYANDTHINK } { thinktime 5 }
            } elseif {$choice <= 23} {
                if { $KEYANDTHINK } { keytime 2 }
                ostat $mysql_handler $w_id $prepare $RAISEERROR
                if { $KEYANDTHINK } { thinktime 5 }
            }
        }
        if {$prepare} {
            foreach st {neword_st payment_st delivery_st slev_st ostat_st} {
                catch {mysqlexec $mysql_handler "deallocate prepare $st"}
            }
        }
mysqlclose $mysql_handler
}
}
