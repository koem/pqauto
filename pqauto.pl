#!/usr/bin/perl

# This perl script tries to store multiple pocket queries that
# get all caches in a defined region.
# 
# IMPORTANT:
# After running the script, you have to activate the queries on
# http://www.geocaching.com/pocket/
#
# The script will print out a link which you can use to see what
# queries were made. As a web link is restricted to 2048
# characters, it might be, that some queries will not be shown 
# on the map. You can use the tool for your own GC-needs 
# (projections, radiuses, ...). Search for "gcdrawlink" in this 
# script to find the link.
#

use warnings;
use strict;

use POSIX;
use WWW::Mechanize;
use WWW::Mechanize::Image;
use Crypt::SSLeay;
use List::Util qw[min max];
use Math::Trig;

# get arguments from command line

# login
my $username = shift;
my $password = shift;

# boundaries
my $bnorth = shift;
my $bwest = shift;
my $bsouth = shift;
my $beast = shift;

# queries
my $querynameprefix = shift;

# check if all arguments are there
if (! defined $querynameprefix) {
    print "Usage: pqauto.pl <username> <password> <north> <west> <south> <east> <prefix>\n";
    print "  <username>   your geocaching.com user name\n";
    print "  <password>   your geocaching.com password\n";
    print "  <north> ...  boundaries for query\n";
    print "  <prefix>     prefix for query names\n";
    exit;
}

my $erad = 6371; # for km
my $maxradiussqr = int(750.0 / sqrt(2));

my $agent = WWW::Mechanize->new( autocheck => 1 );
my $gcdrawlink = "http://koemski.tipido.net/gc/gcdraw.html?";
my $gpxcount = 0;
my $daytogenerate = 6; # 0=sun, 6=sat


&checkarguments;
&login;
my $startradius = &getstartradius;
&createqueries($bnorth, $bwest, $bsouth, $beast, $startradius);

print $gcdrawlink . "\n";

exit;

sub checkarguments {
    if ($bnorth <= $bsouth) {
        print "Boundaries Error: north must be higher than south.\n";
        exit
    }
    if ($beast <= $bwest) {
        print "Boundaries Error: east must be higher than west.\n";
        exit;
    }
}

sub getstartradius {
    my $lonkm = ceil(&distance($bnorth, $bwest, $bsouth, $bwest));
    my $maxlat = &thicker($bnorth, $bsouth);
    my $latkm = ceil(&distance($maxlat, $bwest, $maxlat, $beast));

    my $km = min($lonkm, $latkm);

    if ($km < 1) {
        $km = 1;
    } elsif ($km > $maxradiussqr) {
        $km = $maxradiussqr;
    }
    print "Starting with radius $km km\n";
    return $km
}

sub login {
    print "logging in ...\n";

    my $r = $agent->get('https://www.geocaching.com/login/default.aspx');

    # print $r->decoded_content;

    $agent->form_name('aspnetForm');
    $agent->tick('ctl00$ContentBody$cbRememberMe', 'on');
    $agent->field('ctl00$ContentBody$tbUsername', $username);
    $agent->field('ctl00$ContentBody$tbPassword', $password);
    $r = $agent->click('ctl00$ContentBody$btnSignIn');

    # print $r->decoded_content;
}

sub thicker {
    my $n = shift;
    my $s = shift;
    if ($n > 0 && $s < 0) {
        return 0; # equator when north is above and south below
    } else {
        # nearest one to equator. sign (=hemisphere) does not matter for calculation
        return min(abs($n), abs($s)); 
    }
}

sub createqueries {
    my $north = shift; # as decimal degrees
    my $west = shift;
    my $south = shift;
    my $east = shift;
    my $radius = shift; # as km

    my $w = int(&distance($north, $west, $north, $east));
    my $h = int(&distance($north, $west, $south, $west));

    $gcdrawlink .= "p" . $north . "," . $west . ":90:" . $w . "km:white&";
    $gcdrawlink .= "p" . $north . "," . $east . ":270:" . $w . "km:white&";
    $gcdrawlink .= "p" . $north . "," . $west . ":180:" . $h . "km:white&";
    $gcdrawlink .= "p" . $south . "," . $east . ":0:" . $h . "km:white&";
    $gcdrawlink .= "p" . $south . "," . $west . ":90:" . $w . "km:white&";
    $gcdrawlink .= "p" . $south . "," . $east . ":270:" . $w . "km:white&";
    
    #
    # strategy:
    # - walk from west to east, north to south to make several queries
    # - as the longitudes get narrower in direction to the poles, 
    #   determine the distance to the next center point for a query
    #   using the latitude nearer to the equator
    #

    # determine latitude difference. this doesn't change, lats are
    # always spaced equally

    # divide by sqrt(2) - only use the rectangle that fits into the circle
    # subtract 1 for safety
    my $latdiff = rad2deg(($radius - 1) / sqrt(2) / $erad);
print "latdiff: $latdiff\n";

    for (my $lat = $north; $lat > $south; $lat -= 2 * $latdiff) {
        # determine longitude difference by walking to the east
        # on the latitude which is nearest to the equator (latmax)
        # because there the earth is thicker and the spacing of the
        # longitudes is wider
        my $latsouth = $lat - 2 * $latdiff;
        my $latmax = &thicker($lat, $latsouth);
        my $londiff = &km2lon(($radius - 1) / sqrt(2), $latmax);
print "londiff: $londiff\n";

        for (my $lon = $west; $lon < $east; $lon += 2 * $londiff) {
            my $ctrlat = $lat - $latdiff;
            my $ctrlon = $lon + $londiff;

            printf "query %0.6f,%0.6f radius %d: ", $ctrlat, $ctrlon, $radius;
            my $qryres = &gcquery($ctrlat, $ctrlon, $radius, 0);
            $qryres =~ /results in (.*) caches/;
            if (!defined($1)) {
                print $qryres, "\n\nERROR!\n";
                print $gcdrawlink . "\n";
                exit;
            }
            print $1, " caches. ";
            if ($1 >= 1000) {
                # recursion?

                if ($radius == 1) { 
                    # we can't get all caches in this point!
                    # (cannot really happen, just for precaution)
                    # lets take what we have ...
                    print "Too much caches in this area. ";
                    $gcdrawlink .= sprintf("c%0.6f,%0.6f:%dkm:black&", $ctrlat, $ctrlon, $radius);
                    &savequery;
                    next;
                }

                # recursion

                print "Going nearer and ";
                &deletequery;
                &createqueries($lat, $lon, $lat - 2 * $latdiff, $lon + 2 * $londiff, ceil($radius / 2));
            } elsif ($1 > 0) {
                $gcdrawlink .= sprintf("c%0.6f,%0.6f:%dkm:red&", $ctrlat, $ctrlon, $radius);
                &savequery;
            } else {
                &deletequery;
            }

            if ($londiff == 0) { # this will happen, when radius is 1 km
                last;
            }
        }
        
        if ($latdiff == 0) { # this will happen, when radius is 1 km 
            last;
        }
    }

}

sub distance {
    my $lat1 = shift;
    my $lon1 = shift;
    my $lat2 = shift;
    my $lon2 = shift;

    my $rLat = deg2rad($lat2 - $lat1);
    my $rLon = deg2rad($lon2 - $lon1);
    my $rLat1 = deg2rad($lat1);
    my $rLat2 = deg2rad($lat2);

    my $a = sin($rLat / 2) * sin($rLat / 2) + sin($rLon / 2) * sin($rLon / 2) * cos($rLat1) * cos($rLat2);
    my $c = 2 * atan2(sqrt($a), sqrt(1-$a));
    return $erad * $c;
}

sub deletequery {
    print "Deleting query\n";
    $agent->click('ctl00$ContentBody$btnDelete');
}

sub savequery {
    $gpxcount += 1;
    my $qname = $querynameprefix . sprintf("%04d", $gpxcount);
    print "Saving query ", $qname, "\n";
    $agent->field('ctl00$ContentBody$tbName', $qname);
    # $agent->tick('ctl00$ContentBody$cbDays$'.$daytogenerate, 'on');
    $agent->click('ctl00$ContentBody$btnSubmit');
}

sub gcquery {

    my $ctrlat = shift;
    my $ctrlon = shift;
    my $radius = shift;
    my $mail = shift;

    my @kos = &getquerykos($ctrlat, $ctrlon);

    $agent->get('http://www.geocaching.com/pocket/gcquery.aspx');

    $agent->form_name('aspnetForm');

    $agent->field('ctl00$ContentBody$tbName', 'testq');
    $agent->field('ctl00$ContentBody$LatLong', '1');
    $agent->field('ctl00$ContentBody$tbRadius', $radius);
    $agent->field('ctl00$ContentBody$rbUnitType', 'km');
    $agent->field('ctl00$ContentBody$LatLong:_selectNorthSouth', $kos[0]);
    $agent->field('ctl00$ContentBody$LatLong$_inputLatDegs', $kos[1]);
    $agent->field('ctl00$ContentBody$LatLong$_inputLatMins', $kos[2]);
    $agent->field('ctl00$ContentBody$LatLong:_selectEastWest', $kos[3]);
    $agent->field('ctl00$ContentBody$LatLong$_inputLongDegs', $kos[4]);
    $agent->field('ctl00$ContentBody$LatLong$_inputLongMins', $kos[5]);
    $agent->field('ctl00$ContentBody$tbResults', '1000');
    $agent->tick('ctl00$ContentBody$cbIncludePQNameInFileName', 'on');

    # unused options - maybe they don't need to be here ...
    $agent->field('ctl00$ContentBody$DateTimeBegin$Day', '4');
    $agent->field('ctl00$ContentBody$DateTimeEnd$Year', '2013');
    $agent->field('ctl00$ContentBody$ddDifficultyScore', '1');
    $agent->field('ctl00$ContentBody$CountryState', 'rbNone');
    $agent->field('ctl00$ContentBody$ddLastPlaced', 'WEEK');
    $agent->field('ctl00$ContentBody$tbGC', 'GCXXXX');
    $agent->field('ctl00$ContentBody$ddTerrainScore', '1');
    $agent->field('ctl00$ContentBody$Container', 'rbContainerAny');
    $agent->field('ctl00$ContentBody$DateTimeEnd$Month', '1');
    $agent->field('ctl00$ContentBody$rbRunOption', '1');
    $agent->field('ctl00$ContentBody$ddDifficulty', '>=');
    $agent->field('ctl00$ContentBody$DateTimeBegin$Year', '2013');
    $agent->field('ctl00$ContentBody$Type', 'rbTypeAny');
    $agent->tick('ctl00$ContentBody$cbZip', 'on');
    $agent->field('ctl00$ContentBody$ddFormats', 'GPX');
    $agent->field('ctl00$ContentBody$DateTimeBegin$Month', '1');
    $agent->field('ctl00$ContentBody$DateTimeEnd$Day', '11');
    $agent->field('ctl00$ContentBody$tbPostalCode', '');
    $agent->field('ctl00$ContentBody$ddTerrain', '>=');
    $agent->field('ctl00$ContentBody$Placed', 'rbPlacedNone');
    $agent->field('ctl00$ContentBody$Origin', 'rbOriginWpt');

    my $r = $agent->click('ctl00$ContentBody$btnSubmit');
    return $r->decoded_content;
}

sub getquerykos {
    my $lat = shift;
    my $lon = shift;

    my $ns = 1;
    if ($lat < 0) { $ns = -1; }
    my $ew = 1;
    if ($lon < 0) { $ew = -1; }

    my $latgrad = int(abs($lat));
    my $longrad = int(abs($lon));

    my $latmins = sprintf("%0.3f", (abs($lat) - $latgrad) * 60);
    my $lonmins = sprintf("%0.3f", (abs($lon) - $longrad) * 60);

    return ($ns, $latgrad, $latmins, $ew, $longrad, $lonmins);
}

sub km2lon {
    my $km = shift;
    my $lat = shift;

    my $rdist = $km / $erad;
    my $rlat = deg2rad($lat);

    return rad2deg(atan2(sin($rdist) * cos($rlat), 
            cos($rdist) - sin($rlat) * sin($rlat)));
}

