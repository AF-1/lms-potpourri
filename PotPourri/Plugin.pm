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

package Plugins::PotPourri::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::OPMLBased);

use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Utils::Unicode;
use List::Util qw(shuffle);
use Time::HiRes qw(time);
use Slim::Schema;
use Data::Dumper;

use Plugins::PotPourri::Settings;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.potpourri',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_POTPOURRI',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.potpourri');
my %sortOptionLabels;
my ($apc_enabled, $material_enabled);

sub getDisplayName { 'PLUGIN_POTPOURRI' }

sub initPlugin {
	my $class = shift;
	#$class->SUPER::initPlugin(@_);
	initPrefs();
	if (main::WEBUI) {
		require Plugins::PotPourri::Settings;
		require Plugins::PotPourri::PlayerSettings;
		Plugins::PotPourri::Settings->new($class);
		Plugins::PotPourri::PlayerSettings->new();
	}

	Slim::Menu::PlaylistInfo->registerInfoProvider(potpourri_changeplsortorder => (
		after => 'addplaylist',
		func => sub {
			return playlistSortContextMenu(@_);
		},
	));

	Slim::Web::Pages->addPageFunction('playlistsortorderselect', \&changePLtrackOrder_web);
	Slim::Web::Pages->addPageFunction('playlistsortorderoptions.html', \&changePLtrackOrder_web);

	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorderoptions', '_playlistid', '_playlistname'], [1, 1, 1, \&changePLtrackOrder_jive_choice]);
	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorder', '_playlistid', '_sortoption', '_playlistname'], [1, 0, 1, \&changePLtrackOrder_jive]);

	Slim::Control::Request::subscribe(\&setStartVolumeLevel,[['power']]);
	Slim::Control::Request::subscribe(\&initPLtoplevellink,[['rescan'],['done']]);

	if ($prefs->get('appitem')) {
		$class->SUPER::initPlugin(
			feed => \&handleFeed,
			tag => 'potpourri',
			is_app => 1,
		);
	} else {
		$class->SUPER::initPlugin(@_);
	}
}

sub handleFeed {
	my ($client, $callback, $params, $args) = @_;
	$log->debug('client ID:'.$client->name.' ## client ID:'.$client->id);

	my $items = [
		{
			name => cstring($client, 'PLUGIN_POTPOURI_CLIENTPL_CHANGEORDER').' '.$client->name,
			type => 'link',
			url => \&getSortOptions,
		},
	];
	$callback->({
		items => $items
	});
}

sub getSortOptions {
	my ($client, $cb, $params) = @_;

	my @sortOptionKeys = sort {$a <=> $b} keys (%sortOptionLabels);

	my $sortOptions = [];

	foreach (@sortOptionKeys) {
		next if $sortOptionLabels{$_} =~ '(APC)' && !$apc_enabled;
		push @{$sortOptions}, {
					name => $sortOptionLabels{$_},
					url => \&changeClientPLTrackOrder,
					passthrough => [{
						sortOption => $_,
					}],
				};
	}
	$cb->($sortOptions);
}

sub changeClientPLTrackOrder {
	my ($client, $cb, $params, $args) = @_;
	return if !$client;

	$log->info('client ID:'.$client->name.' ## client ID:'.$client->id);
	my $started = time();

	my $sortOption = $args->{'sortOption'};
	$log->debug('sortOption = '.Dumper($sortOption));

	my @PLtracks = @{Slim::Player::Playlist::playList($client)};

	if (scalar @PLtracks < 2) {
		$log->warn('No sense in reordering playlists with less than 2 tracks');
		return;
	}

	## sort playlist tracks
	@PLtracks = sortTracks($sortOption, @PLtracks);

	# clear client playlist, add tracks and refresh
	Slim::Player::Playlist::stopAndClear($client);

	Slim::Player::Playlist::addTracks($client, \@PLtracks, 0);
	$client->currentPlaylistModified(1);
	$client->currentPlaylistUpdateTime(Time::HiRes::time());
	Slim::Player::Playlist::refreshPlaylist($client);

	$log->info('Sorting current playlist of client "'.$client->name.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');

	my $items = [
		{
			name => string('PLUGIN_POTPOURI_CLIENTPL_CHANGEORDER_DONE').' '.$sortOptionLabels{$sortOption},
			type => 'text',
		},
		{
			name => string('PLUGIN_POTPOURI_CLIENTPL_CHANGEORDER_DONE_INFO'),
			type => 'text',
		},
	];
	$cb->({
		items => $items
	});
}



sub initPrefs {
	$prefs->init({
		toplevelplaylistname => 'none',
		powerofftime => '01:30',
		appitem => 1,
	});

	$prefs->setValidate({
		validator => sub {
			if (defined $_[1] && $_[1] ne '') {
				return if $_[1] =~ m|[\^{}$@<>"#%?*:/\|\\]|;
				return if $_[1] =~ m|.{61,}|;
			}
			return 1;
		}
	}, 'alterativetoplevelplaylistname');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'presetVolume');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'powerofftime');

	$prefs->setChange(sub {
			$log->debug('Change in toplevelPL config detected. Reinitializing top level PL link.');
			initPLtoplevellink();
		}, 'toplevelplaylistname', 'alterativetoplevelplaylistname');
	$prefs->setChange(\&powerOffClientsScheduler, 'enablescheduledclientspoweroff', 'powerofftime');

	my $i = 1;
	%sortOptionLabels = map { $i++ => $_ } ('Random order', 'Inverted order', 'Artist > album > disc no. > track no.', 'Album > artist > disc no. > track no.', 'Album > disc no. > track no.', 'Genre', 'Year', 'Track number', 'Track title', 'Date added', 'Play count', 'Play count (APC)', 'Date last played', 'Date last played (APC)', 'Rating', 'Dynamic played/skipped value (APC)', 'Track length', 'BPM', 'Bitrate', 'Album artist', 'Composer', 'Conductor', 'Band');
}

sub postinitPlugin {
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	$log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;
	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	$log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initPLtoplevellink();
	}
	powerOffClientsScheduler();
}

sub powerOffClientsScheduler {
	$log->debug('Killing existing timers for scheduled power-off');
	Slim::Utils::Timers::killOneTimer(undef, \&powerOffClientsScheduler);
	my $enableScheduledClientsPowerOff = $prefs->get('enablescheduledclientspoweroff');
	if ($enableScheduledClientsPowerOff) {
		my ($powerOffTimeUnparsed, $powerOffTime);
		$powerOffTimeUnparsed = $powerOffTime = $prefs->get('powerofftime');

		if (defined($powerOffTime) && $powerOffTime ne '') {
			my $time = 0;
			$powerOffTime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;

			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
			my $currenttime = $hour * 60 * 60 + $min * 60;

			if ($currenttime == $powerOffTime) {
				$log->info('Current time '.parse_duration($currenttime).' = scheduled power-off time '.$powerOffTimeUnparsed.'. Powering off all players now.');
				foreach my $client (Slim::Player::Client::clients()) {
					if ($client->power()) {
						$client->stop() if $client->isPlaying();
						$client->power(0);
					}
				}
				Slim::Utils::Timers::setTimer(undef, time() + 120, \&powerOffClientsScheduler);
			} else {
				my $timeleft = $powerOffTime - $currenttime;
				$timeleft = $timeleft + 24 * 60 * 60 if $timeleft < 0; # it's past powerOffTime -> schedule for same time tomorrow
				$log->info(parse_duration($timeleft)." until next scheduled power-off at ".$powerOffTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&powerOffClientsScheduler);
			}
		} else {
			$log->warn('powerOffTime = not defined or empty string');
		}
	}
}

sub initPLtoplevellink {
	$log->debug('Started initializing playlist toplevel link.');
	# deregister item first
	Slim::Menu::BrowseLibrary->deregisterNode('PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST');

	# link to playlist in home menu
	my $toplevelplaylistname = $prefs->get('toplevelplaylistname') || 'none';
	if ($toplevelplaylistname eq 'none') {
		$prefs->set('alterativetoplevelplaylistname', '');
	}
	my $alterativetoplevelplaylistname = $prefs->get('alterativetoplevelplaylistname') || '';
	$log->debug('toplevelplaylistname = '.$toplevelplaylistname);
	$log->debug('alterativetoplevelplaylistname = '.Dumper($alterativetoplevelplaylistname));
	if ($toplevelplaylistname ne 'none') {
		my $homemenuTLPLname;
		if ($alterativetoplevelplaylistname ne '') {
			$log->debug('alterativetoplevelplaylistname = '.$alterativetoplevelplaylistname);
			$homemenuTLPLname = registerCustomString($alterativetoplevelplaylistname);
		} else {
			$homemenuTLPLname = registerCustomString($toplevelplaylistname);
		}
		$log->debug('name of home menu item for linked playlist = '.$homemenuTLPLname);
		my $toplevelplaylistID = getPlaylistIDforName($toplevelplaylistname);
		$log->debug('toplevelplaylistID = '.$toplevelplaylistID);

		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => $homemenuTLPLname,
			params => {'playlist_id' => $toplevelplaylistID},
			feed => \&Slim::Menu::BrowseLibrary::_playlistTracks,
			icon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			jiveIcon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			homeMenuText => $homemenuTLPLname,
			condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
			id => 'PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST',
			weight => 79,
			cache => 0,
		});
	}
	$log->debug('Finished initializing playlist toplevel link.');
}

sub playlistSortContextMenu {
	my ($client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};

	my $playlistID= $obj->id;
	my $playlistName = $obj->name;
	$log->debug('playlist name = '.$playlistName.' ## playlist url = '.Dumper($url));

	if ($tags->{menuMode}) {
		return {
			type => 'redirect',
			jive => {
				actions => {
					go => {
						player => 0,
						cmd => ['potpourri', 'changeplaylisttrackorderoptions', $playlistID, $playlistName],
					},
				}
			},
			name => string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS'),
			favorites => 0,
		};
	} else {
		return {
			type => 'redirect',
			name => $client->string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS'),
			favorites => 0,
			web => {
				url => 'plugins/PotPourri/playlistsortorderselect?playlistid='.$playlistID.'&playlistname='.$playlistName
			},
		};
	}
}

sub changePLtrackOrder_web {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $playlistID = $params->{playlistid};
	my $playlistName = $params->{playlistname};
	$log->debug('playlistID = '.$playlistID.' ## playlistName = '.Dumper($playlistName));

	my $sortOption = $params->{sortoption};
	$log->debug('sortOption = '.Dumper($sortOption));
	$params->{playlistid} = $playlistID;
	$params->{playlistname} = $playlistName;
	$params->{apc_enabled} = 1 if $apc_enabled;

	if ($sortOption) {
		my $failed = changePLtrackOrder($playlistID, $sortOption, $playlistName);
		if ($failed) {
			$params->{failed} = 1;
		} else {
			$params->{orderchanged} = 1;
		}
	}
	return Slim::Web::HTTP::filltemplatefile('plugins/PotPourri/html/playlistsortorderoptions.html', $params);
}

sub changePLtrackOrder_jive_choice {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['potpourri'],['changeplaylisttrackorderoptions']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $playlistID = $request->getParam('_playlistid');
	my $playlistName = $request->getParam('_playlistname');
	$log->debug('playlistid = '.Dumper($playlistID));
	return unless $playlistID;

	my @sortOptionKeys = sort {$a <=> $b} keys (%sortOptionLabels);

	my $windowTitle = string('PLUGIN_POTPOURRI_PLSORTORDER_OPTIONS');
	$request->addResult('window', {text => $windowTitle});

	my $cnt = 0;
	foreach (@sortOptionKeys) {
		next if $sortOptionLabels{$_} =~ '(APC)' && !$apc_enabled;
		my $action = {
			'do' => {
				'player' => 0,
				'cmd' => ['potpourri', 'changeplaylisttrackorder', $playlistID, $_, $playlistName],
			},
			'play' => {
				'player' => 0,
				'cmd' => ['potpourri', 'changeplaylisttrackorder', $playlistID, $_, $playlistName],
			},
		};
		my $displayText = $sortOptionLabels{$_};

		$request->addResultLoop('item_loop', $cnt, 'text', $displayText);
		$request->addResultLoop('item_loop', $cnt, 'style', 'itemNoAction');
		$request->addResultLoop('item_loop', $cnt, 'type', 'redirect');
		$request->addResultLoop('item_loop', $cnt, 'actions', $action);
		$request->addResultLoop('item_loop', $cnt, 'nextWindow', 'parent');
		$cnt++;
	}

	$request->addResult('offset', 0);
	$request->addResult('count', $cnt);
	$request->setStatusDone();
}

sub changePLtrackOrder_jive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isCommand([['potpourri'],['changeplaylisttrackorder']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $playlistID = $request->getParam('_playlistid');
	my $sortOption = $request->getParam('_sortoption');
	my $playlistName = $request->getParam('_playlistname');

	return unless $playlistID && $sortOption;
	$log->debug('playlistid = '.$playlistID.' ## sortOption = '.$sortOption);

	my $failed = changePLtrackOrder($playlistID, $sortOption, $playlistName);

	displayMessage($client, $failed);

	$request->setStatusDone();
}

sub changePLtrackOrder {
	my ($playlistID, $sortOption, $playlistName) = @_;
	if (!$playlistID || !$sortOption) {
		$log->error('Missing playlist id or sort option');
		return 1;
	}

	my $started = time();
	my $playlist = Slim::Schema->find('Playlist', $playlistID);
	return 1 if !blessed($playlist);

	my @PLtracks = $playlist->tracks;
	if (scalar @PLtracks < 2) {
		$log->warn('No sense in reordering playlists with less than 2 tracks');
		return 1;
	}

	## sort playlist tracks
	@PLtracks = sortTracks($sortOption, @PLtracks);

	# update and write playlist
	$playlist->setTracks(\@PLtracks);
	$playlist->update;

	if ($playlist->content_type eq 'ssp') {
		$log->debug('Writing playlist to disk.');
		Slim::Formats::Playlists->writeList(\@PLtracks, undef, $playlist->url);
	}

	Slim::Schema->forceCommit;
	Slim::Schema->wipeCaches;
	if ($playlistName) {
		$log->info('Sorting the playlist "'.$playlistName.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	} else {
		$log->info('Sorting the playlist by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	}

	return 0;
}

sub sortTracks {
	my ($sortOption, @tracks) = @_;
	$log->debug('sortOption = '.Dumper($sortOption));

	# Randomize
	if ($sortOption == 1) {
		@tracks = shuffle(shuffle(@tracks));

	# Invert
	} elsif ($sortOption == 2) {
		@tracks = reverse @tracks

	# By artist > album > disc no. > track no.
	} elsif ($sortOption == 3) {
		@tracks = sort {lc($a->artist->namesort) cmp lc($b->artist->namesort) || lc($a->album->namesort) cmp lc($b->album->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By album > artist > disc no. > track no.
	} elsif ($sortOption == 4) {
		@tracks = sort {lc($a->album->namesort) cmp lc($b->album->namesort) || lc($a->artist->namesort) cmp lc($b->artist->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By album > disc no. > track no.
	} elsif ($sortOption == 5) {
		@tracks = sort {lc($a->album->namesort) cmp lc($b->album->namesort) || ($a->disc || 0) <=> ($b->disc || 0) || ($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By first genre
	} elsif ($sortOption == 6) {
		@tracks = sort {lc($a->genre->namesort) cmp lc($b->genre->namesort)} @tracks;

	# By year
	} elsif ($sortOption == 7) {
		@tracks = sort {($a->year || 0) <=> ($b->year || 0)} @tracks;

	# By track number
	} elsif ($sortOption == 8) {
		@tracks = sort {($a->tracknum || 0) <=> ($b->tracknum || 0)} @tracks;

	# By track title
	} elsif ($sortOption == 9) {
		@tracks = sort {lc($a->titlesort) cmp lc($b->titlesort)} @tracks;

	# By date added
	} elsif ($sortOption == 10) {
		@tracks = sort {($a->addedTime || 0) <=> ($b->addedTime || 0)} @tracks;

	# By play count
	} elsif ($sortOption == 11) {
		@tracks = sort {($b->playcount || 0) <=> ($a->playcount || 0)} @tracks;

	# By play count (APC)
	} elsif ($sortOption == 12) {
		my %lookupHash;
		foreach (@tracks) {
			my $trackURLmd5 = $_->urlmd5;
			$lookupHash{$trackURLmd5} = APCquery($trackURLmd5, 'playCount');
		}
		@tracks = sort {($lookupHash{$b->urlmd5} || 0) <=> ($lookupHash{$a->urlmd5} || 0)} @tracks;

	# By date last played
	} elsif ($sortOption == 13) {
		@tracks = sort {($b->lastplayed || 0) <=> ($a->lastplayed || 0)} @tracks;

	# By date last played (APC)
	} elsif ($sortOption == 14) {
		my %lookupHash;
		foreach (@tracks) {
			my $trackURLmd5 = $_->urlmd5;
			$lookupHash{$trackURLmd5} = APCquery($trackURLmd5, 'lastPlayed');
		}
		@tracks = sort {($lookupHash{$b->urlmd5} || 0) <=> ($lookupHash{$a->urlmd5} || 0)} @tracks;

	# By rating
	} elsif ($sortOption == 15) {
		@tracks = sort {($a->rating || 0) <=> ($b->rating || 0)} @tracks;

	# By dynamic played/skipped value (DPSV) (APC)
	} elsif ($sortOption == 16) {
		my %lookupHash;
		foreach (@tracks) {
			my $trackURLmd5 = $_->urlmd5;
			$lookupHash{$trackURLmd5} = APCquery($trackURLmd5, 'dynPSval');
		}
		@tracks = sort {($lookupHash{$b->urlmd5} || 0) <=> ($lookupHash{$a->urlmd5} || 0)} @tracks;

	# By duration
	} elsif ($sortOption == 17) {
		@tracks = sort {($a->secs || 0) <=> ($b->secs || 0)} @tracks;

	# By BPM
	} elsif ($sortOption == 18) {
		@tracks = sort {($a->bpm || 0) <=> ($b->bpm || 0)} @tracks;

	# By bitrate
	} elsif ($sortOption == 19) {
		@tracks = sort {($a->bitrate || 0) <=> ($b->bitrate || 0)} @tracks;

	# By album artist
	} elsif ($sortOption == 20) {
		@tracks = sort {lc($a->album->contributor->namesort) cmp lc($b->album->contributor->namesort)} @tracks;

	# By composer
	} elsif ($sortOption == 21) {
		@tracks = sort {lc($a->composer->namesort) cmp lc($b->composer->namesort)} @tracks;

	# By conductor
	} elsif ($sortOption == 22) {
		@tracks = sort {lc($a->conductor->namesort) cmp lc($b->conductor->namesort)} @tracks;

	# By band
	} elsif ($sortOption == 23) {
		@tracks = sort {lc($a->band->namesort) cmp lc($b->band->namesort)} @tracks;
	}

	return @tracks;
}

sub setStartVolumeLevel {
	my $request = shift;
	my $client = $request->client();
	return unless defined $client;

	my $clientPrefs = $prefs->client($client);
	my $enabledSetStartVolumeLevel = $clientPrefs->get('enabledsetstartvolumelevel');
	return unless $enabledSetStartVolumeLevel;

	my $curVolume = $serverPrefs->client($client)->get('volume');

	if ($client->power()) {
		my $alarm = Slim::Utils::Alarm->getCurrentAlarm($client);
		return if defined $alarm;

		my $volume = $enabledSetStartVolumeLevel == 2 ? $clientPrefs->get('lastVolume') || 18 : $clientPrefs->get('presetVolume');
		if (!$clientPrefs->get('allowRaise')) {
			$log->debug("allowRaise disabled. Current: ".$curVolume." Target: ".$volume);
			return if ($curVolume <= $volume);
		}
		$log->debug("Setting volume for client '".$client->name()."' to ".($enabledSetStartVolumeLevel == 2 ? "last" : "preset")." $volume");
		$client->execute(["mixer", "volume", $volume]);
	} else {
		$prefs->client($client)->set('lastVolume', $curVolume);
		$log->debug("Saving last volume $curVolume for client '".$client->name()."'");
	}
}


sub APCquery {
	my ($trackURLmd5, $queryType) = @_;
	return if (!$trackURLmd5 || !$queryType);
	my $dbh = getCurrentDBH();
	my $returnVal;
	my $sql = "select ifnull($queryType, 0) from alternativeplaycount where urlmd5 = \"$trackURLmd5\"";
	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_columns(undef, \$returnVal);
	$sth->fetch();
	$sth->finish();
	$log->debug('Current APC '.$queryType.' for trackurlmd5 ('.$trackURLmd5.') = '.$returnVal);
	return $returnVal;
}

sub displayMessage {
	my ($client, $messageType) = @_;

	my $message = '';
	if ($messageType == 1) {
		$message = string('PLUGIN_POTPOURRI_PL_SORTORDER_FAILED');
	} else {
		$message = string('PLUGIN_POTPOURRI_PL_SORTORDER_SUCCESS');
	}

	if (Slim::Buttons::Common::mode($client) !~ /^SCREENSAVER./) {
		$client->showBriefly({'line' => [string('PLUGIN_POTPOURRI'), $message]}, 5);
	}
	if ($material_enabled) {
		Slim::Control::Request::executeRequest(undef, ['material-skin', 'send-notif', 'type:info', 'msg:'.$message, 'client:'.$client->id, 'timeout:5']);
	}
}

sub getPlaylistIDforName {
	my $playlistname = shift;
	my $queryresult = Slim::Control::Request::executeRequest(undef, ['playlists', 0, 1, 'search:'.$playlistname]);
	my $existsPL = $queryresult->getResult('count');
	my $playlistid;
	if ($existsPL > 0) {
		$log->debug("Playlist '".$playlistname."' exists.");
		my $PLloop = $queryresult->getResult('playlists_loop');
		foreach my $playlist (@{$PLloop}) {
			$playlistid = $playlist->{id};
		}
	return $playlistid || '' ;
	} else {
		$log->warn("Couldn't find selected playlist to link to.")
	}
}

sub registerCustomString {
	my $string = shift;
	if (!Slim::Utils::Strings::stringExists($string)) {
		my $token = uc(Slim::Utils::Text::ignoreCase($string, 1));
		$token =~ s/\s/_/g;
		$token = 'PLUGIN_PTP_PLTOPLEVELNAME_' . $token;
		Slim::Utils::Strings::storeExtraStrings([{
			strings => {EN => $string},
			token => $token,
		}]) if !Slim::Utils::Strings::stringExists($token);
		return $token;
	}
	return $string;
}

sub parse_duration {
	use integer;
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
		return 1;
	}
	return 0;
}

sub getCurrentDBH {
	return Slim::Schema->storage->dbh();
}

sub masterOrSelf {
	my $client = shift;
	if (!defined($client)) {
		return $client;
	}
	return $client->master();
}

1;
