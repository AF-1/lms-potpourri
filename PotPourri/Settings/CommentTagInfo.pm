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

package Plugins::PotPourri::Settings::CommentTagInfo;

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
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_POTPOURRI_SETTINGS_COMMENTTAGINFO');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PotPourri/settings/commenttaginfo.html');
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
	return ($prefs);
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result = undef;
	my $maxItemNum = 60;

	# Save buttons config
	if ($paramRef->{saveSettings}) {
		my %configmatrix;
		my %searchstringDone;

		for (my $n = 0; $n <= $maxItemNum; $n++) {
			my $thisconfigID = $paramRef->{"pref_idNum_$n"};
			next if (!$thisconfigID || $thisconfigID eq '' || is_integer($thisconfigID) != 1);
			my $enabled = $paramRef->{"pref_enabled_$n"} // undef;
			my $searchstring = trim_leadtail($paramRef->{"pref_searchstring_$n"} // '');
			next if (($searchstring eq '') || ($searchstring =~ m|[^a-zA-Z0-9 -]|) || ($searchstring =~ m|.{61,}|));
			my $contextmenucategoryname = trim_leadtail($paramRef->{"pref_contextmenucategoryname_$n"} // '');
			next if ($contextmenucategoryname =~ m|[\^{}$@<>"#%?*:/\|\\]|);
			my $contextmenucategorycontent = trim_leadtail($paramRef->{"pref_contextmenucategorycontent_$n"} // '');
			my $contextmenuposition = $paramRef->{"pref_contextmenuposition_$n"};

			my $titleformatname = $paramRef->{"pref_titleformatname_$n"} // '';
			next if ($titleformatname =~ m|[\^{}$@<>"#%?*:/\|\\]|);
			$titleformatname = trim_all(uc($titleformatname));
			my $titleformatdisplaystring = trim_leadtail($paramRef->{"pref_titleformatdisplaystring_$n"} // '');

			next if ((($contextmenucategoryname eq '') || ($contextmenucategorycontent eq '')) && (($titleformatname eq '') || ($titleformatdisplaystring eq '')));


			if (!$searchstringDone{$searchstring}) {
				$configmatrix{$thisconfigID} = {
					'enabled' => $enabled,
					'searchstring' => $searchstring,
					'contextmenucategoryname' => $contextmenucategoryname,
					'contextmenucategorycontent' => $contextmenucategorycontent,
					'contextmenuposition' => $contextmenuposition,
					'titleformatname' => $titleformatname,
					'titleformatdisplaystring' => $titleformatdisplaystring
				};
				$searchstringDone{$searchstring} = 1;
			}
		}
		$prefs->set('commenttaginfoconfigmatrix', \%configmatrix);
		$paramRef->{'commenttaginfoconfigmatrix'} = \%configmatrix;
		main::DEBUGLOG && $log->is_debug && $log->debug('SAVED VALUES = '.Data::Dump::dump(\%configmatrix));

		$result = $class->SUPER::handler($client, $paramRef);
	}
	# push to settings page

	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');
	my $thisconfiglist;
	foreach my $thisconfig (sort keys %{$configmatrix}) {
		main::DEBUGLOG && $log->is_debug && $log->debug('thisconfig = '.$thisconfig);
		my $searchstring = $configmatrix->{$thisconfig}->{'searchstring'};
		main::DEBUGLOG && $log->is_debug && $log->debug('searchstring = '.$searchstring);
		push (@{$thisconfiglist}, {
			'enabled' => $configmatrix->{$thisconfig}->{'enabled'},
			'searchstring' => $configmatrix->{$thisconfig}->{'searchstring'},
			'contextmenucategoryname' => $configmatrix->{$thisconfig}->{'contextmenucategoryname'},
			'contextmenucategorycontent' => $configmatrix->{$thisconfig}->{'contextmenucategorycontent'},
			'contextmenuposition' => $configmatrix->{$thisconfig}->{'contextmenuposition'},
			'titleformatname' => $configmatrix->{$thisconfig}->{'titleformatname'},
			'titleformatdisplaystring' => $configmatrix->{$thisconfig}->{'titleformatdisplaystring'}
		});
	}

	my (@thisconfiglistsorted, @thisconfiglistsortedDisabled);
	foreach my $thisconfig (@{$thisconfiglist}) {
		if (defined $thisconfig->{enabled}) {
			push @thisconfiglistsorted, $thisconfig;
		} else {
			push @thisconfiglistsortedDisabled, $thisconfig;
		}
	}
	@thisconfiglistsortedDisabled = sort {lc($a->{contextmenucategoryname}) cmp lc($b->{contextmenucategoryname})} @thisconfiglistsortedDisabled;
	push (@thisconfiglistsorted, @thisconfiglistsortedDisabled);

	# add empty field
	if ((scalar @thisconfiglistsorted + 1) < $maxItemNum) {
		push(@thisconfiglistsorted, {
			'enabled' => undef,
			'searchstring' => '',
			'contextmenucategoryname' => '',
			'contextmenucategorycontent' => '',
			'contextmenuposition' => '',
			'titleformatname' => '',
			'titleformatdisplaystring' => ''
		});
	}

	$paramRef->{'commenttaginfoconfigmatrix'} = \@thisconfiglistsorted;
	$paramRef->{itemcount} = scalar @thisconfiglistsorted;
	main::DEBUGLOG && $log->is_debug && $log->debug('page list = '.Data::Dump::dump($paramRef->{'commenttaginfoconfigmatrix'}));

	$result = $class->SUPER::handler($client, $paramRef);

	return $result;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}

sub trim_leadtail {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

sub is_integer {
	defined $_[0] && $_[0] =~ /^[+-]?\d+$/;
}

1;
