#!/usr/bin/perl

use Net::SNMP qw(:snmp);
require Data::Dumper;
Data::Dumper->import();
$Data::Dumper::Indent = 1;
use Socket;
use Net::DNS;

my @vlan;
my %bridgeTable;
my %indexTable;
my %macTable;
my %nameTable;
my %ipTable;
my %arpTable;
my $count;

my $router='1.1.1.1';
my $node ='1.1.1.1';
my $comm ='public';
my $version = 'snmpv2c';
my %vars;
my $debug=0;
my $debug1=0;
my $debug3=1;

get_vlan();
get_mac();
get_port();
get_portindex();
corr_ifname2ifindex();
get_assocIP();
get_PortIP();
assimilate();
compare();
#####
# functions
#####

sub get_vlan {
 
 #####
 # Retrieve the VLANs. Use snmpwalk on the vtpVlanState object (.1.3.6.1.4.1.9.9.46.1.3.1.1.2 ):
 #####

 print "Retrieving  vtpVlanState...";

 %vars = getnext( node => $node, comm => $comm, oid => '.1.3.6.1.4.1.9.9.46.1.3.1.1.2' );
 if ( scalar keys %vars ) {
	
	# we want @vlan to be a list of active vlans
	for my $v ( keys %vars ) {
		$v =~ /(\d+)$/;				# get the vlan id
		next if $1 >= 1000;
		next unless $vars{$v} == 1;
		push @vlan, $1;
		}
	}

	print Dumper(\@vlan) if $debug;
	print "There were ".scalar @vlan." responses for OID vtpVlanState to vlan\n";
}

sub get_mac {
 ####
 # Step 2
 # For each VLAN, get the MAC address table (using community string indexing) dot1dTpFdbAddress (.1.3.6.1.2.1.17.4.3.1.1)
 ####

 print "Retrieving dot1dTpFdbAddress...";

 foreach my $v ( @vlan ) {
	%vars = getnext( node => $node, comm => $comm.'@'.$v, oid => '.1.3.6.1.2.1.17.4.3.1.1' );
	if ( scalar keys %vars ) {
		%macTable = ( %macTable, %vars );
	}
 } 
 print Dumper(\%macTable) if $debug;
 print "There were ".(keys %macTable)." responses for macTable OID dot1dTpFdbAddress to macTable\n";
}

sub get_port {
 ####
 # step 3
 # For each VLAN, get the bridge port number, dot1dTpFdbPort (.1.3.6.1.2.1.17.4.3.1.2): 
 ####

 print "Retrieving dot1dTpFdbPort...<br>";

 foreach my $v ( @vlan ) {
	%vars = getnext( node => $node, comm => $comm.'@'.$v, oid => '.1.3.6.1.2.1.17.4.3.1.2' );
		if ( scalar keys %vars  ) {
			%bridgeTable = ( %bridgeTable,  %vars );
		}
	}
 print Dumper(\%bridgeTable) if $debug ;
 print "There were ".(keys %bridgeTable)." responses for bridgeTable OID dot1dTpFdbPort to bridgeTable\n";
}

sub get_portindex {
 ####
 # step 4
 # For each VLAN, get the bridge port to ifIndex (1.3.6.1.2.1.2.2.1.1) mapping, dot1dBasePortIfIndex (.1.3.6.1.2.1.17.1.4.1.2): 
 ####

 print "Retrieving dot1dBasePortIfIndex...<br>";

 foreach my $v ( @vlan ) {
	%vars = getnext( node => $node, comm => $comm.'@'.$v, oid => '.1.3.6.1.2.1.17.1.4.1.2' );
	if ( scalar keys %vars  ) {
		%indexTable = ( %indexTable, %vars );
	}
 }

 print Dumper(\%indexTable) if $debug ;
 print "There were ".(keys %indexTable)." responses for indexTable OID dot1dBasePortIfIndex to indexTable\n";
}

sub corr_ifname2ifindex {
 ####
 # step 5
 # Walk the ifName (.1.3.6.1.2.1.31.1.1.1.1) so that the ifIndex value can be correllated with a proper port name:
 ####

 print "Retrieving ifName...";

 %nameTable = getnext( node => $node, comm => $comm, oid => '.1.3.6.1.2.1.31.1.1.1.1' );

 print Dumper(\%nameTable) if $debug ;
 print "There were ".(keys %nameTable)." responses for nameTable OID ifName to nameTable\n";
}

sub get_assocIP {
 ####
 # step 6
 # now get the ipaddr and connected interface for each dynamic mac
 # note that if a hub is connected, we may have more than 1 ipaddr per port !
 # if we are on a L3 switch, lets just get the arp table
 # atPhysAddress = '.1.3.6.1.2.1.3.1.1.2';
 # atNetAddress = '.1.3.6.1.2.1.3.1.1.3';
 # Walk the arp table to get the keyed arp table, same key as step 7
 # Note that we look for the mac->ip table on the adjacent router/L3 switch selection.
 ####    
	
 print "Retrieving the arp table...\n";
 print "Collecting from adjacent switch/router $router\n" if $router ne $node;

 %arpTable = getnext( node => $router, comm => $comm, oid => '.1.3.6.1.2.1.3.1.1.2' );

 print Dumper(\%arpTable) if $debug3;
 print "There were ".(keys %arpTable)." responses for arpTable OID atPhysAddress to arpTable\n";
}

sub get_PortIP {
 ####
 # step 7
 # Walk the net table to get the static mac's to ip mapping for the target device only
 # this also includes the ifindex xnumber
 # atNetAddress '.1.3.6.1.2.1.3.1.1.3'
 ####

 print "Retrieving the directly connected IP numbered interfaces.<br>";

 my %netTable = getnext( node => $node, comm => $comm, oid => '.1.3.6.1.2.1.3.1.1.3' );

 print Dumper(\%netTable) if $debug;
 print "There were ".(keys %netTable)." responses for netTable OID atNetAddress to netTable\n";
}

sub assimilate {
 ####
 # step 8
 # now lets put it all together
 # we want interface ->[ ip address, ipaddress ,....]
 # to start, get interface -> [ mac, mac ,... ]
 # From Step 2 , there is a MAC address: .1.3.6.1.2.1.17.4.3.1.1.0.208.211.106.71.251 = Hex-STRING: 00 D0 D3 6A 47 FB 
 # From Step 3: .1.3.6.1.2.1.17.4.3.1.2.0.208.211.106.71.251 = INTEGER: 113 
 # This tells you that this MAC address (00 D0 D3 6A 47 FB) is from bridge port number 113. 
 # From Step 4, the bridge port number 113 has an ifIndex number 57 .1.3.6.1.2.1.17.1.4.1.2.113 = INTEGER: 57 
 # From Step 5, the ifIndex 57 corresponds to port 2/49 .1.3.6.1.2.1.31.1.1.1.1.57 = STRING: 2/49
 #####


 print "Assimilating all the data...\n";

 # init the hash with all the interface names
 while ( my ($key, $value) = each %nameTable ) {
	next if $value =~ /^VLAN-/ ;					# duplicates
	$value =~ s/Vl/Vlan/;
	$value =~ s/Nu/Null/;
	$ipTable{$key}{index} = $key;				# use this to sort
	$ipTable{$key}{int} = $value;				# int => int name F0/20 etc.
 }
	
 while ( my ($mkey, $mac) = each %macTable ) {
	my $seen = 0;
	my $bp = $bridgeTable{$mkey};
	my $index = $indexTable{$bp};				# got the ifindex for this mac
	next if $index == 0;						# drop index 0, not sure where  they come from !!

	# there is likely to be more than 1 mac per int.

	while ( my ($akey, $arp) = each %arpTable ) {		# now get this mac->ip address from ourselves, or the adjacent switch, whtaever was selected
		if ( $arp eq $mac ) {
			$seen = 1;
			my ( $null, $null,  $ip ) = split /\./ , $akey , 3 ;
			my ($hostname) = gethostbyaddr(inet_aton($ip), AF_INET);
			push( @{$ipTable{$index}{h}}, [ $ip, $hostname, $mac]);		# push an anonymous ref to array(s) of ip/name triage
		}
	}
	if ( ! $seen ) {
		push( @{$ipTable{$index}{h}}, [$mac,'No IP Address Found']);
	}			
 }

 # now lets add in the statics, for the target device only
 foreach my $i ( keys %netTable ) {
	my ( $index, $tmp,  $ip ) = split /\./ , $i, 3;			# only split the first, gives us mac->ip for vlan, routed interfaces etc.
	my ($hostname) = gethostbyaddr(inet_aton($ip), AF_INET);
	push( @{$ipTable{$index}{h}}, [ $ip, $hostname]);		# push an anonymous ref to array(s) of ip/name triage
 }

 print Dumper(\%ipTable) if $debug1;
 print "There were ".(keys %ipTable)." host records for ipTable\n";
}

sub compare { 
 ####
 # step 9
 # read and compare with the interface file, issue a text dump of changes to apply to switch
 ###

 my %interfaceTable;
 my %seen;

 	foreach my $i ( sort alpha keys %ipTable ) {
		print "interface $ipTable{$i}{int}\n";
		if ( @{$ipTable{$i}{h}} > 1 ) {
			foreach my $dx ( @{$ipTable{$i}{h}} ) {
				print "    $dx->[0]";
				print " \[$dx->[1]\]" if $dx->[1];
				print " \[$dx->[2]\]" if $dx->[2];
				print "\n";
			}
		}
 	
 		else {
 		# print derived descr, as single host connected, and we know its IP/hostname
 			if ( $ipTable{$i}{h}[0][1] and $ipTable{$i}{h}[0][1] ne 'No IP Address Found' ) {
				print "   Connected to $ipTable{$i}{h}[0][1] )\n";
				print "   $ipTable{$i}{h}[0][0] \[$ipTable{$i}{h}[0][1]\]\n";
			}
			else {
				# no IP found, print mac and comment.
				print "     $ipTable{$i}{h}[0][0] \[$ipTable{$i}{h}[0][1]\]\n";
			}
 		}
		print "\n";;
 	}
 	print "! Done\n";
}

sub getnext {

		my %resultHash;
		my %arg = @_;
	
		my ($session, $error) = Net::SNMP->session(
			-hostname  => $arg{node},
			-community => $arg{comm},
			-port      => '161',
			-version   => $version
		);

		if (!defined($session)) {
			$perror .= "$error\n";
			return;
		}

		my $result = $session->get_table(
			-maxrepetitions => 10,
			-baseoid     	=> $arg{oid}
		);

		if (!defined($result)) {
			$perror .= "$error\n";
			$session->close;
			return;
		}
		$session->close;

		while ( my ($key, $value) = each %$result ) {
			$key =~ s/^$arg{oid}\.//;					# drop the leading oid, and the subsequent '.'			
			$resultHash{$key} = $value;
		}
		return %resultHash;								# FIXME move this to a reference.
}

sub alpha {
		local($&, $`, $', $1, $2, $3, $4);
		my ($f,$s); # first and second!

		$f = $ipTable{$a}{index};						# specific to this module
		$s = $ipTable{$b}{index};			

		#print STDERR "f=$f s=$s sort1=$sort1\n";
		# Sort IP addresses numerically within each dotted quad
		if ($f =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
			my($a1, $a2, $a3, $a4) = ($1, $2, $3, $4);
			if ($s =~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) {
				my($b1, $b2, $b3, $b4) = ($1, $2, $3, $4);
				return ($a1 <=> $b1) || ($a2 <=> $b2)
				|| ($a3 <=> $b3) || ($a4 <=> $b4);
			}
		}
		# Sort numbers numerically
		elsif ( $f !~ /[^0-9\.]/ && $s !~ /[^0-9\.]/ ) {
			return $f <=> $s;
		}
		# Handle things like Level1, ..., Level10
		if ($f =~ /^(.*\D)(\d+)$/) {
		    my($a1, $a2) = ($1, $2);
		    if ($s =~ /^(.*\D)(\d+)$/) {
				my($b1, $b2) = ($1, $2);
				return $a2 <=> $b2 if $a1 eq $b1;
		    }
		}
		# Default is to sort alphabetically
		return $f cmp $s;
	}
