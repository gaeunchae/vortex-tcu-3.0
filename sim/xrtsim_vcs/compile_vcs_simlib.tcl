proc usage {} {
    puts stderr "Usage:"
    puts stderr "  vivado -mode batch -source hw/pgsim/compile_vcs_simlib.tcl -tclargs \\"
    puts stderr "    <out_dir> <vcs_bin_dir> ?<gcc_exec_path>? ?<force:0|1>? ?<family>? ?<language>?"
    exit 1
}

proc compile_stat_passed {stat_file} {
    if {![file exists $stat_file]} {
        return 0
    }

    set fh [open $stat_file r]
    set data [read $fh]
    close $fh

    foreach line [split $data "\n"] {
        set line [string trim $line]
        if {$line eq ""} {
            continue
        }
        if {[regexp {=fail([,]|$)} $line]} {
            return 0
        }
    }

    return 1
}

if {[llength $argv] < 2} {
    usage
}

set out_dir [file normalize [lindex $argv 0]]
set vcs_bin_dir [file normalize [lindex $argv 1]]
set gcc_exec_path ""
set force_compile 0
set simlib_family "all"
set simlib_language "all"

if {[llength $argv] >= 3} {
    set gcc_exec_path [lindex $argv 2]
}
if {[llength $argv] >= 4} {
    set force_compile [lindex $argv 3]
}
if {[llength $argv] >= 5} {
    set simlib_family [lindex $argv 4]
}
if {[llength $argv] >= 6} {
    set simlib_language [lindex $argv 5]
}

if {$gcc_exec_path ne ""} {
    set gcc_exec_path [file normalize $gcc_exec_path]
}

file mkdir $out_dir
set setup_file [file join $out_dir "synopsys_sim.setup"]
set stat_file [file join $out_dir ".cxl.stat"]

set cmd [list \
    compile_simlib \
    -simulator vcs \
    -simulator_exec_path $vcs_bin_dir \
    -directory $out_dir \
    -family $simlib_family \
    -language $simlib_language \
    -library all \
    -no_ip_compile]

if {$gcc_exec_path ne ""} {
    lappend cmd -gcc_exec_path $gcc_exec_path
}

if {$force_compile eq "1"} {
    lappend cmd -force
}

puts "INFO: Running [join $cmd { }]"
if {[catch {eval $cmd} result opts]} {
    if {[file exists $setup_file] && [compile_stat_passed $stat_file]} {
        puts "WARNING: compile_simlib returned an error, but compiled libraries look usable."
        puts "WARNING: Vivado/VCS version extraction can fail even when compilation succeeds."
        puts "WARNING: Original message: $result"
    } else {
        puts stderr "ERROR: compile_simlib failed"
        puts stderr $result
        exit 1
    }
}

if {![file exists $setup_file]} {
    puts stderr "ERROR: compile_simlib completed without generating $setup_file"
    exit 2
}

if {![compile_stat_passed $stat_file]} {
    puts stderr "ERROR: compile_simlib status file indicates a failed library compile: $stat_file"
    exit 3
}

puts "INFO: Generated $setup_file"
exit 0
