#
# PotPourri
#
# (c) 2022 AF
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
#

package Plugins::PotPourri::Settings::ReleaseTypes;

use strict;
use warnings;
use utf8;

use base qw(Plugins::PotPourri::Settings::BaseSettings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.potpourri');
my $log = logger('plugin.potpourri');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_RELEASETYPES');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/releasetypes.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(postscan_rltypes));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $callHandler = 1;
	my $maxNoFields = 20;
	if ($paramRef->{'saveSettings'}) {
		my @rltypematrix;

		for (my $n = 0; $n <= $maxNoFields; $n++) {
			my $albumTitleSearchString = trim($paramRef->{"pref_albumtitlesearchstring_$n"} // '');
			my $releaseType = $paramRef->{"pref_releasetype_$n"};
			if (length($albumTitleSearchString) > 0) {
				push(@rltypematrix, {'albumtitlesearchstring' => $albumTitleSearchString, 'releasetype' => $releaseType});
			}
		}
		$prefs->set('rltypematrix', \@rltypematrix);
		$paramRef->{'rltypematrix'} = \@rltypematrix;

		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'rlmanualadjust'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::PotPourri::Common::assignReleaseTypes();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}

	# push to settings page
	$paramRef->{'rltypematrix'} = [];
	my $rltypematrix = $prefs->get('rltypematrix');

	foreach my $thisrlType (@{$rltypematrix}) {
		if ($thisrlType->{'albumtitlesearchstring'}) {
			push(@{$paramRef->{'rltypematrix'}}, $thisrlType);
		}
	}

	# add empty field
	if ((scalar @{$rltypematrix} + 1) < $maxNoFields) {
		push(@{$paramRef->{'rltypematrix'}}, {'albumtitlesearchstring' => '', 'releasetype' => ''});
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub trim {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
