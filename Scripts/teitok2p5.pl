use Getopt::Long;
use Data::Dumper;
use POSIX qw(strftime);
use File::Find;
use LWP::Simple;
use LWP::UserAgent;
use JSON;
use XML::LibXML;
use Encode;

# Pars# Convert the known TEITOK differences to "pure" TEI/P5

$scriptname = $0;

GetOptions ( ## Command line options
            'debug' => \$debug, # debugging mode
            'writeback' => \$writeback, # write back to original file or put in new file
            'file=s' => \$filename, # which UDPIPE model to use
            'folder=s' => \$folder, # Originals folder
            );

$\ = "\n"; $, = "\t";

$parser = XML::LibXML->new(); $doc = "";
eval {
	$doc = $parser->load_xml(location => $filename);
};
if ( !$doc ) { print "Invalid XML in $filename"; exit; };

foreach $tk ( $doc->findnodes("//text") ) {
	$tk->removeAttribute('xml:space');
};

@tokatts = ('xml:id', 'lemma', 'msd', 'pos');

# Convert <dtok> to <tok> (to be dealt with later)
foreach $tk ( $doc->findnodes("//text//tok[dtok]") ) {
	$tk->setName('ab');
	foreach $dtk ( $tk->findnodes("text()") ) {
		$text = $dtk->textContent;
		$tk->removeChild($dtk);
	};
	foreach $att ( $tk->attributes() ) {
		$tk->removeAttribute($att);
	};
	foreach $dtk ( $tk->findnodes("dtok") ) {
		$dtk->setName('tok');
		$form = $dtk->getAttribute('form');
		$txt = $doc->createTextNode( $form );
		$form = $dtk->removeAttribute('form');
		$dtk->addChild($txt);
	};
};

# Deal with the namespace
$doc->firstChild->setAttribute('xmlns', 'http://www.tei-c.org/ns/1.0');

# Convert bbox  to <surface> elements
$pcnt = 1; 
foreach $bboxelm ( $doc->findnodes("//text//*[\@bbox]") ) {
	$bbox = $bboxelm->getAttribute('bbox');
	if ( $bboxelm->getName() eq 'pb' ) {
		$page = $bboxelm;
	} else {
		$page = $bboxelm->findnodes("./preceding::pb")->item(0);
	};
	$pbid = $page->getAttribute('id');
	$spag = $spags{$pbid};
	if ( !$spag ) {
		$spag = $doc->createElement( 'surface' );
		if ( $page->getAttribute('n') ) {
			$spag->setAttribute('n', $page->getAttribute('n'));
		};
		$graph = $doc->createElement( 'graphic' );
		$graph->setAttribute('url', $page->getAttribute('facs'));
		$spag->addChild($graph);
		$facs = $doc->findnodes(".//facsimile")->item(0);
		if ( !$facs ) { 
			$facs = $doc->createElement( 'facsimile' );
			$doc->firstChild->addChild($facs);
		};
		$facs->addChild($spag);
		$spid = 'PF'.$pcnt++; $zcnt{$spid} = 1;
		$spag->setAttribute('xml:id', $spid);
		$spags{$pbid} = $spag;
	} else { $spid = $spag->getAttribute('xml:id'); };
	( $x1, $y1, $x2, $y2 ) = split ( " ", $bboxelm->getAttribute('bbox') );
	$zone = $doc->createElement( 'zone' );
	$zone->setAttribute('ulx', $x1);
	$zone->setAttribute('uly', $x2);
	$zone->setAttribute('lrx', $y1);
	$zone->setAttribute('lry', $y2);
	$zid = $spid.'-Z'.$zcnt{$spid}++;
	$zone->setAttribute('xml:id', $zid);
	$spag->addChild($zone);
	$bboxelm->setAttribute('corresp', '#'.$zid);
	
	# Remove the bbox
	$bboxelm->removeAttribute('bbox');
};

# Convert <tok> to <w> and <pc>
$tcnt = 0;
foreach $tk ( $doc->findnodes("//text//tok") ) {
	$wpc = "w";
	if ( $tk->getAttribute('upos') ) {
		if ( $tk->getAttribute('upos') eq 'PUNCT' ) { $wpc = "pc"; };
	} else {
		$word = $tk->textContent;
		if ( $word =~ /^\p{isPunct}+$/ ) { $wpc = "pc"; };
	};
	$tk->setName($wpc);
	
	if ( $tk->getAttribute('upos') ) {
		# Convert CoNNL-U to msd
		$msd = 'UposTag='.$tk->getAttribute('upos');
		if ( $tk->getAttribute('feats') ne '_') { $msd .= '|'.$tk->getAttribute('feats'); };
		$tk->setAttribute('msd', $msd);
		$tk->removeAttribute('upos');
		$tk->removeAttribute('feats');
		$tk->removeAttribute('xpos');

	};
	
	if ( $tk->getAttribute('head') ) {
		# Convert dependency relations to <linkGrp> elements

		$lnkgrp = $tk->findnodes("./ancestor::s/linkGrp")->item(0);
		if ( !$lnkgrp) { 
			$sent = $tk->findnodes("./ancestor::s")->item(0);
			if ( !$sent ) { $sent = $tk->findnodes("//text")->item(0); }; 
			$lnkgrp = $doc->createElement( 'linkGrp' );
			$lnkgrp->setAttribute('type', 'UD-SYN');
			$sent->addChild($lnkgrp);
		};
		$link = $doc->createElement( 'link' );
		$link->setAttribute('ana', 'ud-syn:'.$tk->getAttribute('deprel'));
		$link->setAttribute('target', '#'.$tk->getAttribute('id').' '.'#'.$tk->getAttribute('head'));
		$lnkgrp->addChild($link);
		
	};

	$tk->setAttribute('xml:id', $tk->getAttribute('id'));
	$tk->removeAttribute('id');

	# Remove all attributes that are not P5
	foreach $att ( $tk->attributes() ) {
		$attname = $att->getName();
		if ( !grep /^$attname$/, @tokatts ) {
			$tk->removeAttribute($attname);
		};
	};
		
};


# Convert sound start/end to <timeline> elements
foreach $utt ( $doc->findnodes("//text//u") ) {
	$start = $utt->getAttribute('start');
	$end = $utt->getAttribute('end');

	$times{$start} = 1;
	$times{$end} = 1;

};
$tlnode = $doc->findnodes("//timeline")->item(0);
if ( !$tlnode ) { 
	$text = $doc->findnodes("//text")->item(0); 
	$tlnode = $doc->createElement( 'timeline' );
	$tlnode->setAttribute('unit', 'ms');
	$text->addChild($tlnode);
};
@timeline = sort {$a <=> $b} keys(%times);
$tidx = 1;
$tlwhen = $doc->createElement( 'when' );
$tlwhen->setAttribute('xml:id', 'T0');
$tlnode->addChild($tlwhen);
$last = 0; $lastidx = 'T0';
foreach $time ( @timeline ) {
	$thisidx = "T".$tidx++;
	$tlwhen = $doc->createElement( 'when' );
	$tlwhen->setAttribute('since', '#'.$lastidx);
	$tlwhen->setAttribute('interval', ($time-$last)*1000);
	$tlnode->addChild($tlwhen);
	$last = $time; $lastidx = $thisidx;
	
	foreach $utt ( $doc->findnodes("//text//u[\@start=\"$time\"]") ) { $utt->setAttribute('start', '#'.$thisidx); };
	foreach $utt ( $doc->findnodes("//text//u[\@end=\"$time\"]") ) { $utt->setAttribute('end', '#'.$thisidx); };
	
}; 

if ( $writeback ) { 
	$outfile = $filename;
	`mv $orgfile $orgfile.teitok`;
} else {
	( $outfile = $filename ) =~ s/\.([^.]+)$/\.p5\.\1/;
};
print "Writing converted file to $outfile\n";
open OUTFILE, ">$outfile";
print OUTFILE $doc->toString;	
close OUTFLE;