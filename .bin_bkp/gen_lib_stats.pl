#! /usr/bin/perl

=head1 NAME

  gen_lib_stats.pl 

=head1 SYNOPSIS

   USAGE: gen_lib_stats.pl --server server-name --env dbi [--library libraryId]

=head1 OPTIONS
  
B<--server,-s>
  Server name that need to be processed.

B<--library,-l>
   Specific libraryId whoes taxonomy info to collect

B<--env,-e>
   Specific environment where this script is executed.  Based on these values
   db connection and file locations are set.  Possible values are
   igs, dbi, ageek or test
   
B<--help,-h>
  This help message


=head1  DESCRIPTION

  This script will process all libraries on a given server.  Get a
  break down of
     ORF types (missing 3', missing 5', incomplete, complete)
     ORF model (bacteria, archaea, phage)
     LIB type (viral only, microbial only, top viral, top microbial)
     FUNCTIONAL and UNClassified
  
  Counts for each categories are stored in _cnt field, and all sequenceIds
  for each categories are stored in an external file.
  
=head1  INPUT

  The input is defined with --server which is a domain name only.
     e.g.: calliope (if server name is calliope.dbi.udel.edu)


=head1  OUTPUT
  
  All counts for each category are stored in "statistics" table on the "server"
  given as input.  All sequenceIds for each category are stored in an
  external file, and its location is stored in db.

=head1  CONTACT

 Jaysheel D. Bhavsar @ bjaysheel[at]gmail[dot]com


==head1 EXAMPLE

 gen_lib_stats.pl --server calliope --env dbi --library 31

=cut


use strict;
use warnings;
use DBI;
use Switch;
use LIBInfo;
use Pod::Usage;
use Data::Dumper;
use UTILS_V;
use MLDBM 'DB_File';
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev pass_through);

BEGIN {
 use Ergatis::Logger;
}

my %options = ();
my $results = GetOptions (\%options,
			 'server|s=s',
			 'library|b=s',
			 'env|e=s',
			 'libList|ll=s',
			 'libFile|lf=s',
			 'outdir|o=s',
			 'log|l=s',
			 'debug|d=s',
			 'help|h') || pod2usage();

## display documentation
if( $options{'help'} ){
   pod2usage( {-exitval => 0, -verbose => 2, -output => \*STDERR} );
}

my $logfile = $options{'log'} || Ergatis::Logger::get_default_logfilename();
my $logger = new Ergatis::Logger('LOG_FILE'=>$logfile,
				 'LOG_LEVEL'=>$options{'debug'});
$logger = $logger->get_logger();
##############################################################################
#### DEFINE GLOBAL VAIRABLES.
##############################################################################
my $db_user;
my $db_pass;
my $dbname;
my $db_host;
my $host;

my $dbh0;
my $dbh1;
my $dbh;
my $mgol;

my $libinfo = LIBInfo->new();
my $libObject;

my $file_loc = $options{outdir};

## make sure everything passed was peachy
&check_parameters(\%options);

my $utils = new UTILS_V;
tie(my %mgol, 'MLDBM', "/usr/local/projects/virome/lookup/mgol.ldb");
$utils->mgol_lookup(\%mgol);
##########################################################################
timer(); #call timer to see when process ended.

##CHNAGE IN LOGIC
my $inst_fxn = $dbh->prepare(qq{INSERT INTO statistics (libraryId,
				fxn_cnt, fxn_id,
				unassignfxn_cnt, unassignfxn_id)
			     VALUES(?,?,?,?,?)
			    });

my $upd_env = $dbh->prepare(qq{UPDATE statistics set allviral_cnt=?, allviral_id=?, topviral_cnt=?,
				   topviral_id=?, allmicrobial_cnt=?, allmicrobial_id=?, topmicrobial_cnt=?,
				   topmicrobial_id=?
			     WHERE libraryId=?});

my $upd_orf_mod = $dbh->prepare(qq{UPDATE statistics set complete_cnt=?,complete_mb=?,complete_id=?,
				      incomplete_cnt=?,incomplete_mb=?,incomplete_id=?,
				      lackstart_cnt=?,lackstart_mb=?,lackstart_id=?,
				      lackstop_cnt=?,lackstop_mb=?,lackstop_id=?
				WHERE libraryId=?});

my $upd_orf_type = $dbh->prepare(qq{UPDATE statistics set archaea_cnt=?,archaea_mb=?,archaea_id=?,
					bacteria_cnt=?,bacteria_mb=?,bacteria_id=?,
					phage_cnt=?,phage_mb=?,phage_id=?
				   WHERE libraryId=?});

my $upd_orfan = $dbh->prepare(qq{UPDATE statistics set orfan_cnt=?, orfan_id=? WHERE libraryId=?});

my $upd_rest = $dbh->prepare(qq{UPDATE statistics set read_cnt=?,read_mb=?,
				   tRNA_cnt=?, tRNA_id=?,
				   rRNA_cnt=?, rRNA_id=?,
				   lineage=?
				WHERE libraryId=?});

my $tax = $dbh->prepare(qq{SELECT b.domain, count(b.domain)
		       FROM blastp b inner join sequence s on s.id=b.sequenceId
		       WHERE b.deleted=0
			  and s.deleted=0
			  and b.database_name LIKE 'UNIREF100P'
			  and s.libraryId = ?
			  and b.sys_topHit = 1
			  and b.e_value <= 0.001
		       GROUP BY b.domain ORDER BY b.domain desc});

my $all_seq = $dbh->prepare(qq{SELECT distinct s.id,s.header,s.size,s.basepair
			   FROM sequence s
			   WHERE s.deleted=0
			     and s.orf=1
			     and s.rRNA=0
			     and s.libraryId=?});

my $sig_seq = $dbh->prepare(qq{SELECT distinct s.id, s.header, s.size
			  FROM blastp b inner join sequence s on b.sequenceId=s.id
			  WHERE b.deleted=0
			    and s.deleted=0
			    and b.e_value <= 0.001
			    and s.orf=1 and s.rRNA=0
			    and (b.database_name like 'UNIREF100P' OR
				b.database_name like 'METAGENOMES')
			    and s.libraryId=?});

my $read = $dbh->prepare(qq{SELECT count(s.id), sum(s.size)
			FROM sequence s
			WHERE s.deleted=0
			  and s.orf=0
			  and s.rRNA=0
			  and s.libraryId=?});

my $tRNA = $dbh->prepare(qq{SELECT t.sequenceId
			FROM tRNA t INNER JOIN sequence s on t.sequenceId=s.id
			WHERE s.libraryId=?
			  and s.deleted=0
			  and s.orf=0
			  and s.rRNA=0});

my $rRNA = $dbh->prepare(qq{SELECT s.id
			FROM sequence s
			WHERE s.libraryId=?
			  and s.deleted=0
			  and s.orf=0
			  and s.rRNA=1});

my $lib_sel = $dbh0->prepare(q{SELECT id FROM library WHERE deleted=0 and server=?});

my $rslt = '';
my @libArray;

#set library array to process
if ($options{library} <= 0){
   $lib_sel->execute($options{server});
   $rslt = $lib_sel->fetchall_arrayref({});
   
   foreach my $lib (@$rslt){
       push @libArray, $lib->{'id'};
   }
} else {
   push @libArray, $options{library};
}

foreach my $libId (@libArray){
  print "Processing libraryId: $libId\n";

  my(@uniref_arr,@meta_arr);

  # get all top blast hits for a given library
  my $top_hits = $dbh->prepare(qq{SELECT distinct b.sequenceId, b.database_name
			  FROM blastp b INNER JOIN sequence s ON s.id = b.sequenceId
			  WHERE s.deleted=0
			     and b.deleted=0
			     and s.libraryId = ?
			     and (b.database_name = 'UNIREF100P'
				   OR b.database_name = 'METAGENOMES')
			     and b.sys_topHit=1
			     and b.e_value <= 0.001
			  GROUP BY b.sequenceId, b.database_name
			  ORDER BY b.sequenceId, b.database_name desc});
  $top_hits->execute(($libId));

  ########################################
  # SPLIT SEQUENCE INTO UNIREF100P ONLY
  # AND METAGENOMES ONLY SET AT
  # EVALUE CUTOFF AT 0.001
  ########################################
  # get uniref and metagenomes exclusive sequences.
  my($curr,$prev,$inst)=(0,0,0);
  while (my @result = $top_hits->fetchrow_array()){
      $curr = $result[0];
      if ($curr != $prev){
	  $inst = 0;
	  $prev = $curr;
      }
      if (($inst==0) && ($result[1] eq "UNIREF100P")) {
	  push(@uniref_arr,$result[0]);
	  $inst=1;
      } elsif ($inst==0){
	  push(@meta_arr,$result[0]);
	  $inst=1;
      }
  }
  $top_hits->finish();

  ###########################################
  # GET FUNCTIONAL AND UNASSIGNED FUNCTIONAL
  # CATEGORIES FOR ALL UNIREF100P SEQUENCES
  # AT EVALUE CUTOFF OF 0.001
  ###########################################

  # for all uniref only sequences get functional/unassigned protein info.
  my $functional_count = 0;
  my $functional_list = "";
  my $unclassified_count = 0;
  my $unclassified_list = "";
  my $null_str = "NULL";

  foreach my $sequenceId(@uniref_arr){
     ## SEARCH IN KEGG DATABASE FIRST
     my $found = 0;
     my $seqadded = 0;

     # get all blast hits for a sequence ($sequenceId)
     # where database is uniref.
     #($functional_count,$functional_list,$found,$seqadded) = getFunctionalList("UNIREF100P",$sequenceId,$functional_count,$functional_list,$found,$seqadded);
     #($functional_count,$functional_list,$found,$seqadded) = getFunctionalList("ACLAME",$sequenceId,$functional_count,$functional_list,$found,$seqadded);
     #($functional_count,$functional_list,$found,$seqadded) = getFunctionalList("KEGG",$sequenceId,$functional_count,$functional_list,$found,$seqadded);
     #($functional_count,$functional_list,$found,$seqadded) = getFunctionalList("SEED",$sequenceId,$functional_count,$functional_list,$found,$seqadded);
     #($functional_count,$functional_list,$found,$seqadded) = getFunctionalList("COG",$sequenceId,$functional_count,$functional_list,$found,$seqadded);

     ##STILL NOT FOUND
     if($found eq 0){
	$unclassified_count++;
	if (length($unclassified_list)){
	   $unclassified_list = $unclassified_list . "," . $sequenceId;
	}
	else { $unclassified_list = $sequenceId; }
     }
  }

  ###############################################
  # CALCULATE ENVIRONMENTAL CATEGORIES FOR
  # EACH LIBRARY, VIRAL ONLY, TOP VIRAL,
  # MICORBIAL ONLY, TOP MICORBIAL
  # AT EVALUE CUTOFF AT 0.001
  ###############################################
  my %env=();
  $env{'top_viral'}=0;
  $env{'top_viral_list'}="";
  $env{'top_micro'}=0;
  $env{'top_micro_list'}="";
  $env{'viral'}=0;
  $env{'viral_list'}="";
  $env{'micro'}=0;
  $env{'micro_list'}="";
  
  my $cnt = 0;
  
  foreach my $seqid (@meta_arr){
      $cnt ++;
      # get all blast hits for a seq.
      my $sth = $dbh->prepare(qq{SELECT b.id, b.hit_name, b.sys_topHit, b.query_name
			      FROM blastp b
			      WHERE b.sequenceId=?
				and b.e_value<=0.001
				and b.deleted=0
				and b.database_name='METAGENOMES'
			      ORDER BY b.id,b.sys_topHit});
       $sth->execute(($seqid));

      #my $seq="";
      my $other_hits="";
      my $top_hit="";
      
      # loop through all blast results for a sequence
      while (my $row = $sth->fetchrow_hashref){
	 my $mgol_acc_hash = $utils->get_acc_from_lookup("mgol",substr($$row{hit_name},0,3));
	 
	 if (defined $mgol_acc_hash){
	    my $mgol_hash = $mgol_acc_hash->{acc_data}[0];
	    
	    print $$row{id} ."\t". $$row{hit_name} ."\t". $mgol_hash->{lib_type}."\t".$$row{sys_topHit}."\n";
	    
	    if ($mgol_hash->{lib_type} ne 'UNKNOWN'){
	       
	       if ($$row{sys_topHit} == 1){ # processing top hit
		  if ($mgol_hash->{lib_type} =~ /viral/i){
		     $top_hit = "viral";
		  } else {
		     $top_hit = "micro";
		  }
	       } else { # processing all other hits
		  if ($mgol_hash->{lib_type} =~ /viral/i){
		     $other_hits = "viral";
		  } else {
		     $other_hits = "micro";
		  }
	       }
	       
	    } else {
	       print STDERR "Cannot find mgol entry for $$row{hit_name}\n";
	    }
	 } else {
	    print STDERR "Cannot find mgol entry for $$row{hit_name}\n";
	 }

	 #my $prefix = substr($$rslt{hit_name},0,3);

	 #my $lib_type = $mgol->prepare(qq{SELECT m.lib_type
	 #				FROM mgol_library m
	 #				WHERE m.lib_prefix=?
	 #				 and m.deleted=0});
	 
	 #$lib_type->execute($prefix);
	 #my ($env_type) = $lib_type->fetchrow_array();
	 #if (! defined($env_type)){
	 #   $env_type = "";
	 #   print STDERR "Cannot find mgol entry for $prefix for $$rslt{hit_name}\n";
	 #}
	  
	 #if ($$rslt{sys_topHit}==1){
	 #     if ($env_type eq "Viral"){
	 #	  $top="viral";
	 #     } else { $top="micro"; }
	 #} else {
	 #     if ($env_type eq "Viral"){
	 #	  $tmp="viral";
	 #     } else { $tmp="micro"; }
	 #}
	 #$seq = $rslt[3];
      }
      
      # viral or microbial only assignment.
      # if both $top_hit and $other_hits are same or
      # $other_hit is empyt i.e only one hit
      my $env_type = $top_hit;
      my $env_type_list = $env_type ."_list";
      
      # have multiple hits and top hit is different form other hits.
      # it is possible for $top_hit ne $other_hit if only one hit
      if (($top_hit ne $other_hits) && length($other_hits)){
	 $env_type = "top_" . $top_hit;
	 $env_type_list = $env_type ."_list";
      }
      
      print "----------------".$env_type . "\n\n";
      
      $env{$env_type} += 1;
      if (length($env{$env_type_list})){
	 $env{$env_type_list} .= "," . $seqid;
      } else {
	 $env{$env_type_list} = $seqid;
      }
      

      #print "top is $top and rest is $tmp for $seq\n";
      #if (($top_hit ne $other_hits) && (length($other_hits))){
	  # update top v/m count and id list
	 # $tmp = "top_" . $top;
	 # $env{$tmp} = $env{$tmp}+1;
	 # $tmp = "top_" . $top . "_list";
	 # if (length($env{$tmp})){
	 #     $env{$tmp} = $env{$tmp} . "," . $seqid;
	 # } else { $env{$tmp} = $seqid; }
      #} elsif (!length($tmp)){
	  # if only one hit then treat it as all viral/microbial
	 # $env{$top} = $env{$top}+1;
	 # $tmp = $top ."_list";
	 # if (length($env{$tmp})){
	 #     $env{$tmp} = $env{$tmp} . "," . $seqid;
	 # } else { $env{$tmp} = $seqid; }
      #} else {
	  # update v/m count and id list
	 # $env{$tmp} = $env{$tmp}+1;
	 # $tmp = $tmp ."_list";
	 # if (length($env{$tmp})){
	 #     $env{$tmp} = $env{$tmp} . "," . $seqid;
	 # } else { $env{$tmp} = $seqid; }
      #}
      
      last if ($cnt == 5);
  }
  exit();

  #################################################
  # CALCULATE TAXONOMY LINEAGE AT DOMAIN LEVEL
  # AT EVALUE CUTOFF AT 0.001
  #################################################
   ## get domain taxonomy count.
  my ($type,$count,$lineage);
  $tax->execute(($libId));
  $tax->bind_col(1,\$type);
  $tax->bind_col(2,\$count);
  $lineage = "";
  while($tax->fetch) {
     if (!length($type)){
	$type = "Unclassified";
     }
     if (length($lineage)){
	$lineage = $lineage.";".$type.":".$count;
     }
     else { $lineage = $type.":".$count; }
  }
  #print "$lineage\n";


  ##################################################
  # CALCULATE ORF CATEGORIES and TYPES
  # FOR EACH LIBRARY AT EVALUE CUTOFF OF 0.001
  ##################################################
  my %orf=();
  $orf{'comp_cnt'}=0;
  $orf{'comp_lst'}="";
  $orf{'comp_mb'}=0;
  $orf{'incomp_cnt'}=0;
  $orf{'incomp_lst'}="";
  $orf{'incomp_mb'}=0;
  $orf{'start_cnt'}=0;
  $orf{'start_lst'}="";
  $orf{'start_mb'}=0;
  $orf{'stop_cnt'}=0;
  $orf{'stop_lst'}="";
  $orf{'stop_mb'}=0;
  $orf{'bacteria_cnt'}=0;
  $orf{'bacteria_lst'}="";
  $orf{'bacteria_mb'}=0;
  $orf{'archaea_cnt'}=0;
  $orf{'archaea_lst'}="";
  $orf{'archaea_mb'}=0;
  $orf{'phage_cnt'}=0;
  $orf{'phage_lst'}="";
  $orf{'phage_mb'}=0;

  $all_seq->execute(($libId));
  while (my @rslt = $all_seq->fetchrow_array()){
     my $model="";
     my $orf_type="";
     if ($rslt[1] =~ /.*model=(.*) ends=(\d+) .*/){
	$model = $1;

	switch ($2){
	   case "10" { $orf_type= "stop"}
	   case "01" { $orf_type= "start"}
	   case "00" { $orf_type= "incomp"}
	   case "11" { $orf_type= "comp"}
	}

	# set model stats.
	$orf{$model.'_cnt'}++;
	if ($rslt[3] =~ /\*$/){
	   $orf{$model.'_mb'}+=($rslt[2]-1);
	}else {
	   $orf{$model.'_mb'}+=$rslt[2];
	}

	if (length($orf{$model.'_lst'})){
	   $orf{$model.'_lst'} = $orf{$model.'_lst'} . "," . $rslt[0];
	} else { $orf{$model.'_lst'}=$rslt[0]; }

	# set type stats.
	$orf{$orf_type.'_cnt'}++;
	if ($rslt[3] =~ /\*$/){
	   $orf{$orf_type.'_mb'}+=($rslt[2]-1);
	} else { $orf{$orf_type.'_mb'}+=$rslt[2]; }

	if (length($orf{$orf_type.'_lst'})){
	   $orf{$orf_type.'_lst'} = $orf{$orf_type.'_lst'} . "," . $rslt[0];
	} else { $orf{$orf_type.'_lst'}=$rslt[0]; }
     }
  }

  ##################################################
  # GET ORFAN COUNT AT EVALUE CUTOFF OF 0.001
  ##################################################
  my $sigcnt = 0;
  my $siglst = "";

  $sig_seq->execute(($libId));
  my $rslt = $sig_seq->fetchall_arrayref({});
  foreach my $val (@$rslt){
     $sigcnt ++;
     # get all significant hit ids.
     if (length($siglst)){
	$siglst .= "," . $val->{id};
     } else { $siglst = $val->{id}; }
  }

  $all_seq->execute(($libId));
  $rslt = $all_seq->fetchall_arrayref({});
  my $allcount = 0;
  my %orfan=();
  $orfan{'count'}=0;
  $orfan{'lst'}="";
  foreach my $val (@$rslt){
     $allcount++;
     if (index($siglst, $val->{id}) < 0){
	$orfan{'count'}++;
	if (length($orfan{'lst'})){
	   $orfan{'lst'} .= "," . $val->{id};
	} else { $orfan{'lst'} = $val->{id}; }
     }
  }

  ##################################################
  # GET READ COUNT AND MEGABASES
  ##################################################
  $read->execute(($libId));
  my $read_row = $read->fetchall_arrayref([],1);
  my %read_s=();
  $read_s{'count'}=$read_row->[0]->[0];
  $read_s{'mb'} = $read_row->[0]->[1];

  ##################################################
  # GET TRNA COUNT AND LIST
  ##################################################
  $tRNA->execute(($libId));
  my %tRNA_s=();
  $tRNA_s{'count'}=0;
  $tRNA_s{'lst'}="";
  while (my @rslt = $tRNA->fetchrow_array()){
     $tRNA_s{'count'}++;
     if (length($tRNA_s{'lst'})){
	$tRNA_s{'lst'} = $tRNA_s{'lst'} . "," . $rslt[0];
     } else { $tRNA_s{'lst'} = $rslt[0]; }
  }

  ###################################################
  # GET RRNA COUNT AND LIST
  ###################################################
  $rRNA->execute(($libId));
  my %rRNA_s=();
  $rRNA_s{'count'}=0;
  $rRNA_s{'lst'}="";
  while (my @rslt = $rRNA->fetchrow_array()){
     $rRNA_s{'count'}++;
     if (length($rRNA_s{'lst'})){
	$rRNA_s{'lst'} = $rRNA_s{'lst'} . "," . $rslt[0];
     } else { $rRNA_s{'lst'} = $rslt[0]; }
  }


  #################################################
  # INSERT STATISTICS INTO TABLE
  #################################################

  #create output file for functional_id list and unclass_id list
  my $output_dir = $file_loc;
  open(OUT,">".$output_dir."/idFiles/fxnIdList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/fxnIdList_$libId.txt to write\n";
  print OUT $functional_list;
  close OUT;
  
  open(OUT,">".$output_dir."/idFiles/unClassIdList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/unClassIdList_$libId.txt to write\n";
  print OUT $unclassified_list;
  close OUT;

  $inst_fxn->execute(($libId,$functional_count,$output_dir."/idFiles/fxnIdList_$libId.txt",
		  $unclassified_count,$output_dir."/idFiles/unClassIdList_$libId.txt"));

  #create output file for viral and micorbial id list
  open(OUT,">".$output_dir."/idFiles/viralList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/viralList_$libId.txt to write\n";
  print OUT $env{'viral_list'};
  close OUT;
  
  open(OUT,">".$output_dir."/idFiles/topViralList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/topViralList_$libId.txt to write\n";
  print OUT $env{'top_viral_list'};
  close OUT;
  
  open(OUT,">".$output_dir."/idFiles/microList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/microList_$libId.txt to write\n";
  print OUT $env{'micro_list'};
  close OUT;
  
  open(OUT,">".$output_dir."/idFiles/topMicroList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/topMicroList_$libId.txt to write\n";
  print OUT $env{'top_micro_list'};
  close OUT;
  
  $upd_env->execute(($env{'viral'},$output_dir."/idFiles/viralList_$libId.txt",
		  $env{'top_viral'},$output_dir."/idFiles/topViralList_$libId.txt",
		  $env{'micro'},$output_dir."idFiles/microList_$libId.txt",
		  $env{'top_micro'},$output_dir."/idFiles/topMicroList_$libId.txt",$libId));

  open(OUT,">".$output_dir."/idFiles/compORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/compORFList_$libId.txt to write\n";
  print OUT $orf{'comp_lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/incompORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/incompORFList_$libId.txt to write\n";
  print OUT $orf{'incomp_lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/startORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/startORFList_$libId.txt to write\n";
  print OUT $orf{'start_lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/stopORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/stopORFList_$libId.txt to write\n";
  print OUT $orf{'stop_lst'};
  close OUT;

  $upd_orf_mod->execute(($orf{'comp_cnt'},$orf{'comp_mb'},$output_dir."/idFiles/compORFList_$libId.txt",
		  $orf{'incomp_cnt'},$orf{'incomp_mb'},$output_dir."/idFiles/incompORFList_$libId.txt",
		  $orf{'start_cnt'},$orf{'start_mb'},$output_dir."/idFiles/startORFList_$libId.txt",
		  $orf{'stop_cnt'},$orf{'stop_mb'},$output_dir."/idFiles/stopORFList_$libId.txt",$libId));

  open(OUT,">".$output_dir."/idFiles/arcORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/arcORFList_$libId.txt to write\n";
  print OUT $orf{'archaea_lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/bacORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/bacORFList_$libId.txt to write\n";
  print OUT $orf{'bacteria_lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/phgORFList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/phgORFList_$libId.txt to write\n";
  print OUT $orf{'phage_lst'};
  close OUT;

  $upd_orf_type->execute(($orf{'archaea_cnt'},$orf{'archaea_mb'},$output_dir."/idFiles/arcORFList_$libId.txt",
		  $orf{'bacteria_cnt'},$orf{'bacteria_mb'},$output_dir."/idFiles/bacORFList_$libId.txt",
		  $orf{'phage_cnt'},$orf{'phage_mb'},$output_dir."/idFiles/phgORFList_$libId.txt",$libId));

  open(OUT,">".$output_dir."/idFiles/orfanList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/orfanList_$libId.txt to write\n";
  print OUT $orfan{'lst'};
  close OUT;

  $upd_orfan->execute(($orfan{'count'},$output_dir."/idFiles/orfanList_$libId.txt",$libId));

  open(OUT,">".$output_dir."/idFiles/tRNAList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/tRNAList_$libId.txt to write\n";
  print OUT $tRNA_s{'lst'};
  close OUT;

  open(OUT,">".$output_dir."/idFiles/rRNAList_$libId.txt") or die "Could not open file ".$output_dir."/idFiles/rRNAList_$libId.txt to write\n";
  print OUT $rRNA_s{'lst'};
  close OUT;

  $upd_rest->execute(($read_s{'count'},$read_s{'mb'},
		    $tRNA_s{'count'},$output_dir."/idFiles/tRNAList_$libId.txt",
		    $rRNA_s{'count'},$output_dir."/idFiles/rRNAList_$libId.txt",
		    $lineage,$libId));   
}

$dbh0->disconnect;
$dbh1->disconnect;
$dbh->disconnect;
$mgol->disconnect;
timer(); #call timer to see when process ended.
exit(0);

###############################################################################
####  SUBS
###############################################################################

sub check_parameters {
  my $options = shift;

   my $flag = 0;
   
   # if library list file or library file has been specified
   # get library info. server, id and library name.
   if ((defined $options{libFile}) && (length($options{libFile}))){
       $libObject = $libinfo->getLibFileInfo($options{libFile});
       $flag = 1;
   } elsif ((defined $options{libList}) && (length($options{libList}))){
       $libObject = $libinfo->getLibListInfo($options{libList});
       $flag = 1;
   }

   # if server is not specifed and library file is not specifed show error
   if (!$options{server} && !$flag){
     pod2usage({-exitval => 2,  -message => "error message", -verbose => 1, -output => \*STDERR});
     exit(-1);  
   }
   
   # if exec env is not specified show error
   unless ($options{env}) {
     pod2usage({-exitval => 2,  -message => "error message", -verbose => 1, -output => \*STDERR});
     exit(-1);
   }
   
   # if no library info set library to -1;
   unless ($options{library}){
       $options{library} = -1;
   }
   
   # if getting info from library file set server and library info.
   if ($flag){
       $options{library} = $libObject->{id};
       $options{server} = $libObject->{server};
   }
  
  if ($options{env} eq 'dbi'){
      $db_user = q|bhavsar|;
      $db_pass = q|P3^seus|;
      $dbname = q|VIROME|;
      $db_host = $options{server}.q|.dbi.udel.edu|;
      $host = q|virome.dbi.udel.edu|;
   }elsif ($options{env} eq 'diag'){
       $db_user = q|dnasko|;
       $db_pass = q|dnas_76|;
       $dbname = q|virome_processing|;
       $db_host = q|dnode001.igs.umaryland.edu|;
       $host = q|dnode001.igs.umaryland.edu|;
  }elsif ($options{env} eq 'igs'){
       $db_user = q|jbhavsar|;
       $db_pass = q|jbhavsar58|;
       $dbname = q|virome_processing|;
       $db_host = q|hannibal.igs.umaryland.edu|;
       $host = q|hannibal.igs.umaryland.edu|;
  }elsif ($options{env} eq 'ageek') {
      $db_user = q|bhavsar|;
      $db_pass = q|Application99|;
      $dbname = $options{server};
      $db_host = q|10.254.0.1|;
      $host = q|10.254.0.1|;
  }else {
      $db_user = q|kingquattro|;
      $db_pass = q|Un!c0rn|;
      $dbname = q|VIROME|;
      $db_host = q|localhost|;
      $host = q|localhost|;
  }
	      
  $dbh0 = DBI->connect("DBI:mysql:database=virome_processing;host=$host",
      "$db_user", "$db_pass",{PrintError=>1, RaiseError =>1, AutoCommit =>1});
  
  $dbh1 = DBI->connect("DBI:mysql:database=uniref_lookup2;host=$host",
      "$db_user", "$db_pass",{PrintError=>1, RaiseError =>1, AutoCommit =>1});

  $mgol = DBI->connect("DBI:mysql:database=virome_processing;host=$host",
     "$db_user", "$db_pass", {PrintError=>1, RaiseError =>1, AutoCommit =>1});
  
  $dbh = DBI->connect("DBI:mysql:database=$dbname;host=$db_host",
      "$db_user", "$db_pass",{PrintError=>1, RaiseError =>1, AutoCommit =>1});

  $dbh0->{RaiseError} = 1;
  $dbh1->{RaiseError} = 1;
  $dbh->{RaiseError} = 1;
  $mgol->{RaiseError} =1 ;
}

###############################################################################
sub getFunctionalList{

  my ($db,$seqId,$functional_count,$functional_list,$found,$seqadded) = @_;
  my $null_str = "NULL";
  my $flag = 0;
  
  my $db_hits = $dbh->prepare(qq{SELECT b.id, b.hit_name
			    FROM blastp b
			    WHERE b.database_name=?
			     and b.sequenceId=?
			     and b.e_value<=0.001
			     and b.deleted=0
			    ORDER BY b.e_value asc});
  my $update_fxn_flag = $dbh->prepare(qq{update blastp set fxn_topHit = 1 WHERE id = ?});

  # hit_name is already set to realacc from clean_expand_btab
  # script so just check if fxn1 has a meaningfull value .
  # no lookup required for acc.
  my $fxn_hit_info = $dbh1->prepare(get_fxn_query($db));
  
  # get all blast hits for a sequence ($sequenceId) and a given database
  $db_hits->execute($db,$seqId);
  my $result = $db_hits->fetchall_arrayref({});

  # loop through each blast hit against given database
  foreach my $blst_row (@$result){
    # check if blast hit has a uniref100 accession.
    if ((defined $blst_row->{hit_name}) && ($blst_row->{hit_name} ne $null_str) && (length($blst_row->{hit_name}))){
      
      # get hit information.
      $fxn_hit_info->execute($blst_row->{hit_name});
      my $fxn_rslt = $fxn_hit_info->fetchall_arrayref({});
      
      # for each records if there is a informative data
      # update fxn value.
      foreach my $fxn_row (@$fxn_rslt){
	if ( (defined $fxn_row->{fxn1}) && (length($fxn_row->{fxn1}) > 0) && ($fxn_row->{fxn1} ne $null_str) &&
	    !($fxn_row->{fxn1} =~ /unknown|unclassified|unassigned|uncharacterized/i) &&
	    ($flag eq 0)){
	      $update_fxn_flag->execute($blst_row->{id});
	      $flag = 1;
	      $found = 1;
	}
	last if ($flag);
      }
    }

    # if fxn flag updated no need to continue further.
    last if ($flag);
  }

  #SEQUENCE HAD AN FUNCTIONAL ASSIGNMENT
  if (($found eq 1) && ($seqadded eq 0)){
     #ADD TO THE LIST
     $functional_count++;
     if (length($functional_list)){
	$functional_list = $functional_list. "," . $seqId;
     } else {
	$functional_list = $seqId;
     }
     $seqadded = 1;
  }

  return ($functional_count,$functional_list,$found,$seqadded);
}

###############################################################################
sub get_fxn_query{
  my $db = $_[0];

  switch ($db){
     case "UNIREF100P"{ return q|SELECT gc.name as fxn1 FROM gofxn g INNER JOIN go_chains gc ON g.chain_id=gc.chain_id
			      WHERE gc.level=1 and g.realAcc = ?|; }
     case "ACLAME" { return q|SELECT mc.name as fxn1 FROM aclamefxn a INNER JOIN mego_chains mc ON a.chain_id=mc.chain_id
			      WHERE mc.level=1 and a.realAcc = ?|; }
     case "SEED" { return q|SELECT fxn1 from seed where realacc = ?|; }
     case "KEGG" { return q|SELECT fxn1 from kegg where realacc = ?|; }
     case "COG" { return q|SELECT fxn1 from cog where realacc = ?|; }
     else { return ""; }
  }
}

###############################################################################
sub timer {
   my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
   my @weekDays = qw(Sun Mon Tue Wed Thu Fri Sat Sun);
   my ($second, $minute, $hour, $dayOfMonth, $month, $yearOffset, $dayOfWeek, $dayOfYear, $daylightSavings) = localtime();
   my $year = 1900 + $yearOffset;
   my $theTime = "$hour:$minute:$second, $weekDays[$dayOfWeek] $months[$month] $dayOfMonth, $year";
   print "Time now: " . $theTime."\n";
}
