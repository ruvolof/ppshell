#! /usr/bin/perl

use strict;
use warnings;
use experimental "switch";
use threads;
use threads::shared;
use IO::Handle;
use IO::Select;

autoflush STDOUT 1;

use Data::Dumper qw(Dumper);
use Net::OpenSSH;

use constant CMD_IDF => '/';
use constant SSH_INSTANCE => 'SSH_INSTANCE';
use constant CHANNELS => 'CHANNELS';
use constant CURR_READER => 'CURR_READER';
use constant GMEMBERS => 'GMEMBERS';

my %ssh_connections;
my %groups;
my $active_conn;
my $pmode = 0;

sub print_prompt {
    my $p = '$ ';
    if (defined $active_conn) {
        $p = $active_conn . ' ' . $p;
    }
    print $p;
}

sub handle_input {
    my $l = $_[0];
    chomp($l);
    if ($pmode) {
        system("stty", "echo");
        $pmode = 0;
    }
    
    if (index($l, CMD_IDF) == 0) {
        command_handler($l);
    }
    elsif (defined $active_conn and exists $ssh_connections{$active_conn}) {
        print {$ssh_connections{$active_conn}{CHANNELS}[0]} $l, "\n";
    }
    elsif (defined $active_conn and exists $groups{$active_conn}) {
        for my $ch (@{$groups{$active_conn}{GMEMBERS}}) {
            if (exists $ssh_connections{$ch}) {
                print {$ssh_connections{$ch}{CHANNELS}[0]} $l, "\n";
            }
        }
    }
    else {
        print "No active shell found. Select or open one.\n";
    }
}

sub command_handler {
    my $cmd = $_[0];
    my @args = split / /, $cmd;
    
    for ($args[0]) {
        when (/^\/e(xit)?\b/) { do_exit() }
        when (/^\/o(pen)?\b/) { open_new_shell(@args) }
        when (/^\/r(ead)?\b/) { output_reader() }
        when (/^\/sw(itch)?\b/) { switch_active(@args) }
        when (/^\/c(lose)?\b/) { close_shell(@args) }
        when (/^\/p(assmode)?\b/) { password_mode() }
        when (/^\/ag(roup)?\b/) { add_group(@args) }
        when (/^\/rg(roup)?\b/) { rm_group(@args) }
        when (/^\/lsg(roup)?\b/) { ls_group(@args) }
    }
}

sub do_exit {
    print "Bye.\n";
    exit 0;
}

sub output_reader {
    if (defined $active_conn and exists $ssh_connections{$active_conn}) {
        my $fh = $ssh_connections{$active_conn}{CHANNELS}[1];
        while (read $fh, my $c, 100) {
            print $c;
        }
    }
    elsif (defined $active_conn and exists $groups{$active_conn}) {
        for my $h (@{$groups{$active_conn}{GMEMBERS}}) {
            print "Output from $h:\n";
            my $fh = $ssh_connections{$h}{CHANNELS}[1];
            while (read $fh, my $c, 100) {
                print $c;
            }
            print "\n";
        }
    }
}

sub open_new_shell {
    if (scalar @_ < 2) {
        print STDERR "Error: /open needs at least an host.\n";
        return;
    }

    my $ep = $_[1];

    my $nssh = Net::OpenSSH->new($ep);
    $nssh->error and print "SSH connection failed: " . $nssh->error and return;
    my @connection_channels = $nssh->open2({tty => 0, stderr_to_stdout => 1});
    $connection_channels[1]->blocking(0);
    $connection_channels[1]->autoflush();
  
    $ssh_connections{$ep}{SSH_INSTANCE} = $nssh;
    $ssh_connections{$ep}{CHANNELS} = [@connection_channels];
    $active_conn = $ep;
}

sub switch_active {
    if (scalar @_ < 2) {
        print STDERR "Error: /switch needs at least a shell.\n";
        return;
    }

    my $sh = $_[1];
    if (exists $ssh_connections{$sh}) {
        $active_conn = $sh;
        print "Active host: $sh.\n";
    }
    elsif (exists $groups{$sh}) {
        $active_conn = $sh;
        print "Active group: $sh.\n"
    }
    else {
        print "Host not found. Use /open to open a new connections.\n"
    }
}

sub close_shell {
    if (scalar @_ < 2) {
        print STDERR "Error: /close needs at least an host.\n";
        return;
    }

    my $sh = $_[1];
    if ($sh eq "all") {
        foreach my $key (keys %ssh_connections) {
            $ssh_connections{$key}{SSH_INSTANCE}->disconnect(0);
            delete $ssh_connections{$key};
        }
        undef $active_conn;
        print "Disconnected from all shells.\n";
    }
    elsif (exists $ssh_connections{$sh}) {
        $ssh_connections{$sh}{SSH_INSTANCE}->disconnect(0);
        delete $ssh_connections{$sh};
        if ($sh eq $active_conn) {
            undef $active_conn;
        }
        print "Disconnected from $sh.\n";
    }
    else {
        print "Shell not found.\n";
    }
}

sub password_mode {
    system("stty", "-echo");
    $pmode = 1;
}

sub add_group {
    if (scalar @_ < 3) {
        print STDERR "Error: /agroup needs an host and a group.\nUsage: /addgroup host group\n";
        return;
    }
    
    my ($host, $group) = ($_[1], $_[2]);
    my $valid_names = '^\s*[a-zA-Z0-9\.]+\s*$';
    if ($host =~ /$valid_names/ and $group =~ /$valid_names/) {
        if (not exists $groups{$group}) {
            $groups{$group} = {};
            $groups{$group}{GMEMBERS} = ();
        }
        push @{$groups{$group}{GMEMBERS}}, $host;
        print $host, ' correctly added to group ', $group, "\n";
    }
    else {
        print STDERR "Error: host and group can only have letters, numbers and dots.\n";
    }
}

sub rm_group {
    if (scalar @_ < 3) {
        print STDERR "Error: /rgroup needs an host and a group.\nUsage: /rgroup host group\n";
    }
    
    my ($host, $group) = ($_[1], $_[2]);
    if (exists $groups{$group}) {
        if ($host eq 'all') {
            @{$groups{$group}{GMEMBERS}} = ();
        }
        else {
            @{$groups{$group}{GMEMBERS}} = grep {!/$host/} @{$groups{$group}{GMEMBERS}};
        }
        print $host, ' removed from ', $group, "\n";
    }
    else {
        print "Group ", $group, " not found.\n";
    }
}

sub ls_group {
    print "Group\t\tConnections\n";
    if (scalar @_ < 2) {
        my @gls = keys %groups;
        if (scalar @gls == 0) {
            print "-\t\t-\n";
        }
        else {
            for my $g (@gls) {
                print "$g:\t\t@{$groups{$g}{GMEMBERS}}\n";
            }
        }
    }   
}

print_prompt();
while (my $l = <>) {
    handle_input($l);
    print_prompt();
}
