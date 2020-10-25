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

use constant CMD_IDF      => '\\';
use constant SSH_INSTANCE => 'SSH_INSTANCE';
use constant CHANNELS     => 'CHANNELS';
use constant CURR_READER  => 'CURR_READER';
use constant GMEMBERS     => 'GMEMBERS';
use constant INITFILE     => "$ENV{'HOME'}/.ppshellrc";

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
  my $cmd  = $_[0];
  my @args = split / /, $cmd;

  my $c = substr $args[0], 1;

  for ($c) {
      when (/^h(elp)?\b/) { print_help() }
      when (/^e(xit)?\b/) { do_exit() }
      when (/^o(pen)?\b/) { open_new_shell(@args) }
      when (/^r(ead)?\b/) { output_reader() }
      when (/^lsh(ost)?\b/) { list_hosts() }
      when (/^sw(itch)?\b/) { switch_active(@args) }
      when (/^c(lose)?\b/) { close_shell(@args) }
      when (/^p(assmode)?\b/) { password_mode() }
      when (/^ag(roup)?\b/) { add_group(@args) }
      when (/^rg(roup)?\b/) { rm_group(@args) }
      when (/^lsg(roup)?\b/) { ls_group(@args) }
      when (/^s(ave)?\b/) { save_conf() }
      default { print "$c: command not found\n" }
  }
}

sub print_help {
  my $help = "ppshell v0.1\n";
  $help .= "Commands have to be prepended by " . CMD_IDF . ".\n";
  $help .= "h/help\t\tPrint this help.\n";
  $help .= "e/exit\t\tExits ppshell.\n";
  $help .= "o/open\t\tOpen ssh connection.\n";
  $help .= "r/read\t\tRead commands output.\n";
  $help .= "lsh/lshost\tList established connections.\n";
  $help .= "sw/switch\tSwitch active connection. Can use a group name.\n";
  $help .= "c/close\t\tClose connection.\n";
  $help .= "p/passmode\tHides input in ppshell.\n";
  $help .= "ag/agroup\tAdd host to a group.\n";
  $help .= "rg/rgroup\tRemove host from group.\n";
  $help .= "lsg/lsgroup\tList groups.\n";
  $help .=
    "s/save\t\tSave current connections to restore them on next launch.\n";

    print $help;
}

sub do_exit {
  close_shell(CMD_IDF . 'c', 'all');
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
      for my $h (@{ $groups{$active_conn}{GMEMBERS}}) {
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
  my @connection_channels =
    $nssh->open2({tty => 0, stderr_to_stdout => 1});
  $connection_channels[1]->blocking(0);
  $connection_channels[1]->autoflush();

  $ssh_connections{$ep}{SSH_INSTANCE} = $nssh;
  $ssh_connections{$ep}{CHANNELS} = [@connection_channels];
  $active_conn = $ep;
}

sub list_hosts {
  if (scalar(%ssh_connections) > 0) {
      print "Available connections:\n";
      for my $k (keys %ssh_connections) {
          print "- $k\n";
      }
  }
  else {
      print "No active connections found.";
  }
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
      print "Active group: $sh.\n";
  }
  else {
      print "Host not found. Use " . CMD_IDF . "open to open a new connections.\n";
  }
}

sub close_shell {
  if (scalar @_ < 2) {
      print STDERR "Error: " . CMD_IDF . "close needs at least an host.\n";
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
      if ($active_conn and $sh eq $active_conn) {
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
      print STDERR
        "Error: " . CMD_IDF . "agroup needs an host and a group.\n".
        "Usage: ". CMD_IDF . "addgroup host group\n";
      return;
  }

  my ($host, $group) = ( $_[1], $_[2] );
  my $valid_names = '^\s*[a-zA-Z0-9\.@]+\s*$';
  if ($host =~ /$valid_names/ and $group =~ /$valid_names/) {
      if (not exists $groups{$group}) {
          $groups{$group} = {};
          $groups{$group}{GMEMBERS} = ();
      }
      push @{$groups{$group}{GMEMBERS}}, $host;
      print $host, ' correctly added to group ', $group, "\n";
  }
  else {
      print STDERR
        "Error: host and group can only have letters, numbers and dots.\n";
  }
}

sub rm_group {
  if (scalar @_ < 3) {
      print STDERR
        "Error: " . CMD_IDF . "rgroup needs an host and a group.\n".
        "Usage: " . CMD_IDF . "rgroup host group\n";
  }

  my ($host, $group) = ($_[1], $_[2]);
  if (exists $groups{$group}) {
      if ($host eq 'all') {
          @{$groups{$group}{GMEMBERS}} = ();
      }
      else {
          @{$groups{$group}{GMEMBERS}} =
            grep {!/$host/} @{$groups{$group}{GMEMBERS}};
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

sub save_conf {
  open (my $fh, '>', INITFILE);
  print $fh join(',', keys %ssh_connections), "\n";
  for my $g (keys %groups) {
      print $fh $g, ':', join(',', @{$groups{$g}{GMEMBERS}}), "\n";
  }
  close($fh);
}

print "ppshell v0.1 - Type '". CMD_IDF . "h' for a list of commands.\n";

if (-e INITFILE) {
  open(my $fh, '<', INITFILE);
  my $l = <$fh>;
  chomp $l;
  for my $c (split /,/, $l) {
    open_new_shell(CMD_IDF . 'o', $c);
  }
  while ($l = <$fh>) {
    chomp $l;
    my ($g, $m) = split /:/, $l;
    $groups{$g} = {};
    @{$groups{$g}{GMEMBERS}} = split /,/, $m;
  }
  close($fh);
  print INITFILE, " loaded.\n";
  undef $active_conn;
}

print_prompt();
while (my $l = <>) {
  handle_input($l);
  print_prompt();
}
