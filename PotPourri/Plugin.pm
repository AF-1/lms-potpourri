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
use POSIX qw(strftime);
use Slim::Schema;
use File::Spec::Functions qw(:ALL);

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.potpourri',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_POTPOURRI',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.potpourri');
my %sortOptionLabels;
my ($apc_enabled, $material_enabled);

use Plugins::PotPourri::Common ':all';
use Plugins::PotPourri::Importer;


sub initPlugin {
	my $class = shift;

	initPrefs();
	if (main::WEBUI) {
		require Plugins::PotPourri::Settings::Basic;
		require Plugins::PotPourri::Settings::Export;
		require Plugins::PotPourri::Settings::CommentTagInfo;
		require Plugins::PotPourri::PlayerSettings;
		require Plugins::PotPourri::Settings::ReleaseTypes;
		Plugins::PotPourri::Settings::Basic->new($class);
		Plugins::PotPourri::Settings::Export->new($class);
		Plugins::PotPourri::Settings::CommentTagInfo->new($class);
		Plugins::PotPourri::PlayerSettings->new();
		Plugins::PotPourri::Settings::ReleaseTypes->new($class);
	}

	Slim::Menu::PlaylistInfo->registerInfoProvider(potpourri_changeplsortorder => (
		after => 'addplaylist',
		func => sub {
			return playlistSortContextMenu(@_);
		},
	));
	if ($prefs->get('displaytrackid')) {
		Slim::Menu::TrackInfo->registerInfoProvider('zppt_infotrackid' => (
			parent => 'moreinfo', isa => 'bottom',
			func => sub { return getTrackIdForContextMenu(@_); }
		));
	}

	Slim::Web::Pages->addPageFunction('playlistsortorderselect', \&changePLtrackOrder_web);
	Slim::Web::Pages->addPageFunction('playlistsortorderoptions.html', \&changePLtrackOrder_web);

	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorderoptions', '_playlistid', '_playlistname'], [1, 1, 1, \&changePLtrackOrder_jive_choice]);
	Slim::Control::Request::addDispatch(['potpourri', 'changeplaylisttrackorder', '_playlistid', '_sortoption', '_playlistname'], [1, 0, 1, \&changePLtrackOrder_jive]);

	Slim::Control::Request::subscribe(\&setStartVolumeLevel,[['power']]);
	Slim::Control::Request::subscribe(\&initPLtoplevellink,[['rescan'],['done']]);

	initExportBaseFilePathMatrix();

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

sub initPrefs {
	$prefs->init({
		toplevelplaylistname => 'none',
		powerofftime => '01:30',
		appitem => 1,
	});

	$prefs->set('status_exportingtoplaylistfiles', '0');

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 100}, 'presetVolume');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'powerofftime');

	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Change in toplevelPL config detected. Reinitializing top level PL link.');
			initPLtoplevellink();
		}, 'toplevelplaylistname');
	$prefs->setChange(\&powerOffClientsScheduler, 'enablescheduledclientspoweroff', 'powerofftime');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Change in comment tag info config matrix detected. Reinitializing trackinfohandler & titleformats.');
			initMatrix();
			Slim::Music::Info::clearFormatDisplayCache();
		}, 'commenttaginfoconfigmatrix');
	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('De-/reregistering infoprovider.');
			Slim::Menu::TrackInfo->deregisterInfoProvider('zppt_infotrackid');
			if ($prefs->get('displaytrackid')) {
				Slim::Menu::TrackInfo->registerInfoProvider('zppt_infotrackid' => (
					parent => 'moreinfo', isa => 'bottom',
					func => sub { return getTrackIdForContextMenu(@_); }
				));
			}
		}, 'displaytrackid');
	my $i = 1;
	%sortOptionLabels = map { $i++ => $_ } ('Random order', 'Inverted order', 'Artist > album > disc no. > track no.', 'Album > artist > disc no. > track no.', 'Album > disc no. > track no.', 'Genre', 'Year', 'Track number', 'Track title', 'Date added', 'Play count', 'Play count (APC)', 'Date last played', 'Date last played (APC)', 'Rating', 'Dynamic played/skipped value (APC)', 'Track length', 'BPM', 'Bitrate', 'Album artist', 'Composer', 'Conductor', 'Band');
}

sub postinitPlugin {
	$apc_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::AlternativePlayCount::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Alternative Play Count" is enabled') if $apc_enabled;
	$material_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Material Skin" is enabled') if $material_enabled;

	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initPLtoplevellink();
	}
	powerOffClientsScheduler();
	initMatrix();
}


sub playlistSortContextMenu {
	my ($client, $url, $obj, $remoteMeta, $tags) = @_;
	$tags ||= {};

	my $playlistID= $obj->id;
	my $playlistName = $obj->name;
	main::DEBUGLOG && $log->is_debug && $log->debug('playlist name = '.$playlistName.' ## playlist url = '.Data::Dump::dump($url));

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
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistID = '.$playlistID.' ## playlistName = '.Data::Dump::dump($playlistName));

	my $sortOption = $params->{sortoption};
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));
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
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistid = '.Data::Dump::dump($playlistID));
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
	main::DEBUGLOG && $log->is_debug && $log->debug('playlistid = '.$playlistID.' ## sortOption = '.$sortOption);

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
		main::DEBUGLOG && $log->is_debug && $log->debug('Writing playlist to disk.');
		Slim::Formats::Playlists->writeList(\@PLtracks, undef, $playlist->url);
	}

	Slim::Schema->forceCommit;
	Slim::Schema->wipeCaches;
	if ($playlistName) {
		main::INFOLOG && $log->is_info && $log->info('Sorting the playlist "'.$playlistName.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	} else {
		main::INFOLOG && $log->is_info && $log->info('Sorting the playlist by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');
	}

	return 0;
}

sub handleFeed {
	my ($client, $callback, $params, $args) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('client ID:'.$client->name.' ## client ID:'.$client->id);

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

	main::INFOLOG && $log->is_info && $log->info('client ID:'.$client->name.' ## client ID:'.$client->id);
	my $started = time();

	my $sortOption = $args->{'sortOption'};
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));

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

	main::INFOLOG && $log->is_info && $log->info('Sorting current playlist of client "'.$client->name.'" by "'.$sortOptionLabels{$sortOption}.'" took '.(time()-$started).' seconds');

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

sub sortTracks {
	my ($sortOption, @tracks) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('sortOption = '.Data::Dump::dump($sortOption));

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


# export static playlists with new paths/file extensions
sub exportPlaylistsToFiles {
	my $playlistID = shift;
main::INFOLOG && $log->is_info && $log->info('playlistID = '.Data::Dump::dump($playlistID));

	my $status_exportingtoplaylistfiles = $prefs->get('status_exportingtoplaylistfiles');
	if ($status_exportingtoplaylistfiles == 1) {
		$log->warn('Export is already in progress, please wait for the previous export to finish');
		return;
	}
	$prefs->set('status_exportingtoplaylistfiles', 1);

	my $exportDir = $serverPrefs->get('playlistdir') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $started = time();

	my $playlist = Slim::Schema->find('Playlist', $playlistID);
	return if !blessed($playlist);

	my @PLtracks = $playlist->tracks;
	my $trackCount = scalar(@PLtracks);

	if ($trackCount > 0) {
		my $exporttimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
		my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
		my $PLfilename = 'PPT_Export_'.$filename_timestamp.'_'.$playlist->title.'.m3u.txt';

		my $filename = catfile($exportDir, $PLfilename);
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does LMS have read/write permissions (755) for the LMS playlist folder?');
			$prefs->set('status_exportingtoplaylistfiles', 0);
			return;
		};
		print $output '#EXTM3U'."\n";
		print $output '# exported with \'PotPourri\' LMS plugin ('.$exporttimestamp.")\n";
		print $output '# contains '.$trackCount.($trackCount == 1 ? ' track' : ' tracks')."\n\n";
		for my $thisTrack (@PLtracks) {
			my $thisTrackURL = $thisTrack->get('url');
			my $thisTrackURL_extURL = changeExportFilePath($thisTrackURL, 1) if ($thisTrack->get('remote') != 1);
			print $output '#EXTURL:'.$thisTrackURL_extURL."\n" if $thisTrackURL_extURL && $thisTrackURL_extURL ne '';

			my $thisTrackPath = pathForItem($thisTrackURL);
			$thisTrackPath = Slim::Utils::Unicode::utf8decode_locale(pathForItem($thisTrackURL)); # diff
			$thisTrackPath = changeExportFilePath($thisTrackPath) if ($thisTrack->get('remote') != 1);

			print $output $thisTrackPath."\n";
		}
		close $output;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('TOTAL number of tracks exported: '.$trackCount);
	$prefs->set('status_exportingtoplaylistfiles', 0);
	main::DEBUGLOG && $log->is_debug && $log->debug('Export completed after '.(time() - $started).' seconds.');
}

sub changeExportFilePath {
	my $trackURL = shift;
	my $isEXTURL = shift;
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');

	if (scalar @{$exportbasefilepathmatrix} > 0) {
		my $oldtrackURL = $trackURL;
		my $escaped_trackURL = escape($trackURL);
		my $exportextension = $prefs->get('exportextension');
		my $exportExtensionExceptionsString = $prefs->get('exportextensionexceptions');

		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			my $lmsbasepath = $thispath->{'lmsbasepath'};
			main::INFOLOG && $log->is_info && $log->info("\n\n\nisEXTURL = ".Data::Dump::dump($isEXTURL));
			main::INFOLOG && $log->is_info && $log->info('trackURL = '.Data::Dump::dump($oldtrackURL));
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL = '.$escaped_trackURL);
			if ($isEXTURL) {
				$lmsbasepath =~ s/\\/\//isg;
				$escaped_trackURL =~ s/%2520/%20/isg;
			}
			main::INFOLOG && $log->is_info && $log->info('escaped_trackURL after EXTURL regex = '.$escaped_trackURL);

			my $escaped_lmsbasepath = escape($lmsbasepath);
			main::INFOLOG && $log->is_info && $log->info('escaped_lmsbasepath = '.$escaped_lmsbasepath);

			if (($escaped_trackURL =~ $escaped_lmsbasepath) && (defined ($thispath->{'substitutebasepath'})) && (($thispath->{'substitutebasepath'}) ne '')) {
				my $substitutebasepath = $thispath->{'substitutebasepath'};
				main::INFOLOG && $log->is_info && $log->info('substitutebasepath = '.$substitutebasepath);
				if ($isEXTURL) {
					$substitutebasepath =~ s/\\/\//isg;
				}
				my $escaped_substitutebasepath = escape($substitutebasepath);
				main::INFOLOG && $log->is_info && $log->info('escaped_substitutebasepath = '.$escaped_substitutebasepath);

				if (defined $exportextension && $exportextension ne '') {
					my ($LMSfileExtension) = $escaped_trackURL =~ /(\.[^.]*)$/;
					$LMSfileExtension =~ s/\.//s;
					main::INFOLOG && $log->is_info && $log->info("LMS file extension is '$LMSfileExtension'");

					# file extension replacement - exceptions
					my %extensionExceptionsHash;
					if (defined $exportExtensionExceptionsString && $exportExtensionExceptionsString ne '') {
						$exportExtensionExceptionsString =~ s/ //g;
						%extensionExceptionsHash = map {$_ => 1} (split /,/, lc($exportExtensionExceptionsString));
						main::DEBUGLOG && $log->is_debug && $log->debug('extensionExceptionsHash = '.Data::Dump::dump(\%extensionExceptionsHash));
					}

					if ((scalar keys %extensionExceptionsHash > 0) && $extensionExceptionsHash{lc($LMSfileExtension)}) {
						main::INFOLOG && $log->is_info && $log->info("The file extension '$LMSfileExtension' is not replaced because it is included in the list of exceptions.");
					} else {
						$escaped_trackURL =~ s/\.[^.]*$/\.$exportextension/isg;
					}
				}

				$escaped_trackURL =~ s/$escaped_lmsbasepath/$escaped_substitutebasepath/isg;
				main::INFOLOG && $log->is_info && $log->info('escaped_trackURL AFTER regex replacing = '.$escaped_trackURL);

				$trackURL = Encode::decode('utf8', unescape($escaped_trackURL));
				main::INFOLOG && $log->is_info && $log->info('UNescaped trackURL = '.$trackURL);

				if ($isEXTURL) {
					$trackURL =~ s/ /%20/isg;
				} else {
					$trackURL = Slim::Utils::Unicode::utf8decode_locale($trackURL);
				}
				main::INFOLOG && $log->is_info && $log->info('old url: '.$oldtrackURL."\nlmsbasepath = ".$lmsbasepath."\nsubstitutebasepath = ".$substitutebasepath."\nnew url = ".$trackURL);
			}
		}
	}
	return $trackURL;
}

sub initExportBaseFilePathMatrix {
	# get LMS music dirs
	my $lmsmusicdirs = getMusicDirs();
	my $exportbasefilepathmatrix = $prefs->get('exportbasefilepathmatrix');
	if (!defined $exportbasefilepathmatrix) {
		my $n = 0;
		foreach my $musicdir (@{$lmsmusicdirs}) {
			push(@{$exportbasefilepathmatrix}, {lmsbasepath => $musicdir, substitutebasepath => ''});
			$n++;
		}
		$prefs->set('exportbasefilepathmatrix', $exportbasefilepathmatrix);
	} else {
		# add new music dirs as options if not in list
		my @currentlmsbasefilepaths;
		foreach my $thispath (@{$exportbasefilepathmatrix}) {
			push (@currentlmsbasefilepaths, $thispath->{'lmsbasepath'});
		}

		my %seen;
		@seen{@currentlmsbasefilepaths} = ();

		foreach my $newdir (@{$lmsmusicdirs}) {
			push (@{$exportbasefilepathmatrix}, {lmsbasepath => $newdir, substitutebasepath => ''}) unless exists $seen{$newdir};
		}
		$prefs->set('exportbasefilepathmatrix', \@{$exportbasefilepathmatrix});
	}
}


# use comment tag info for song info & title formats
sub initMatrix {
	main::DEBUGLOG && $log->is_debug && $log->debug('Start initializing trackinfohandler & titleformats.');
	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');

	if (keys %{$configmatrix} > 0) {
		foreach my $thisconfig (keys %{$configmatrix}) {
			my $enabled = $configmatrix->{$thisconfig}->{'enabled'};
			next if (!defined $enabled);

			my $thisconfigID = $thisconfig;
			main::DEBUGLOG && $log->is_debug && $log->debug('thisconfigID = '.$thisconfigID);
			my $regID = 'PPT_TIHregID_'.$thisconfigID;
			main::DEBUGLOG && $log->is_debug && $log->debug('trackinfohandler ID = '.$regID);
			Slim::Menu::TrackInfo->deregisterInfoProvider($regID);

			my $searchstring = $configmatrix->{$thisconfig}->{'searchstring'};
			my $contextmenucategoryname = $configmatrix->{$thisconfig}->{'contextmenucategoryname'};
			my $contextmenucategorycontent = $configmatrix->{$thisconfig}->{'contextmenucategorycontent'};

			if (defined $searchstring && defined $contextmenucategoryname && defined $contextmenucategorycontent) {
				my $contextmenuposition = $configmatrix->{$thisconfig}->{'contextmenuposition'};
				my $possiblecontextmenupositions = [
					"after => 'artwork'", # 0
					"after => 'bottom'", # 1
					"parent => 'moreinfo', isa => 'top'", # 2
					"parent => 'moreinfo', isa => 'bottom'" # 3
				];
				my $thisPos = @{$possiblecontextmenupositions}[$contextmenuposition];
				Slim::Menu::TrackInfo->registerInfoProvider($regID => (
					eval($thisPos),
					func => sub {
						return getTrackInfo(@_,$thisconfigID);
					}
				));
			}
			my $titleformatname = $configmatrix->{$thisconfig}->{'titleformatname'};
			my $titleformatdisplaystring = $configmatrix->{$thisconfig}->{'titleformatdisplaystring'};
			if (defined $searchstring && defined $titleformatname && defined $titleformatdisplaystring) {
				my $TF_name = 'PPT_'.uc(trim_all($titleformatname));
				main::DEBUGLOG && $log->is_debug && $log->debug('titleformat name = '.$TF_name);
				addTitleFormat($TF_name);
				Slim::Music::TitleFormatter::addFormat($TF_name, sub {
				return getTitleFormat(@_, $thisconfigID);
				}, 1);
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished initializing trackinfohandler & titleformats.');
}

sub getTrackInfo {
	my ($client, $url, $track, $remoteMeta, $tags, $filter, $thisconfigID) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('thisconfigID = '.$thisconfigID);

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return;
	}

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($url) == 1)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('ignoring remote track without comments tag: '.$url);
		return;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($url) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track dead or moved??? Track URL: '.$url);
		return;
	}

	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');
	my $thisconfig = $configmatrix->{$thisconfigID};
		if (($thisconfig->{'searchstring'}) && ($thisconfig->{'contextmenucategoryname'}) && ($thisconfig->{'contextmenucategorycontent'})) {
			my $itemname = $thisconfig->{'contextmenucategoryname'};
			my $itemvalue = $thisconfig->{'contextmenucategorycontent'};
			my $thiscomment = $track->comment;

			if (defined $thiscomment && $thiscomment ne '') {
				if (index(lc($thiscomment), lc($thisconfig->{'searchstring'})) != -1) {

					main::DEBUGLOG && $log->is_debug && $log->debug('text = '.$itemname.': '.$itemvalue);
					return {
						type => 'text',
						name => $itemname.': '.$itemvalue,
						itemvalue => $itemvalue,
						itemid => $track->id,
					};
				}
			}
		}
	return;
}

sub getTitleFormat {
	my $track = shift;
	my $thisconfigID = shift;
	my $TF_string = '';

	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: not available until library scan is completed');
		return $TF_string;
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('getting value for title format ID = '.$thisconfigID);

	if ($track && !blessed($track)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track is not blessed');
		$track = Slim::Schema->find('Track', $track->{id});
		if (!blessed($track)) {
			main::DEBUGLOG && $log->is_debug && $log->debug('No track object found');
			return $TF_string;
		}
	}
	my $trackURL = $track->url;

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($trackURL) == 1)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('ignoring remote track without comments tag: '.$trackURL);
		return $TF_string;
	}

	# check for dead/moved local tracks
	if ((Slim::Music::Info::isRemoteURL($trackURL) != 1) && (!defined($track->filesize))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('track dead or moved??? Track URL: '.$trackURL);
		return $TF_string;
	}

	my $configmatrix = $prefs->get('commenttaginfoconfigmatrix');
	my $thisconfig = $configmatrix->{$thisconfigID};
	my $titleformatname = $thisconfig->{'titleformatname'};
	my $titleformatdisplaystring = $thisconfig->{'titleformatdisplaystring'};
	if (($titleformatname ne '') && ($titleformatdisplaystring ne '')) {
		my $thiscomment = $track->comment;
		if (defined $thiscomment && $thiscomment ne '') {
			if (index(lc($thiscomment), lc($thisconfig->{'searchstring'})) != -1) {
				$TF_string = $titleformatdisplaystring;
			}
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('returned title format display string for track = '.Data::Dump::dump($TF_string));
	return $TF_string;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format (@{$titleFormats}) {
		if($titleformat eq $format) {
			return;
		}
	}
	push @{$titleFormats},$titleformat;
	$serverPrefs->set('titleFormat',$titleFormats);
}

sub trim_leadtail {
	my ($str) = @_;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

sub trim_all {
	my ($str) = @_;
	$str =~ s/ //g;
	return $str;
}


# misc
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
			main::DEBUGLOG && $log->is_debug && $log->debug("allowRaise disabled. Current: ".$curVolume." Target: ".$volume);
			return if ($curVolume <= $volume);
		}
		main::DEBUGLOG && $log->is_debug && $log->debug("Setting volume for client '".$client->name()."' to ".($enabledSetStartVolumeLevel == 2 ? "last" : "preset")." $volume");
		$client->execute(["mixer", "volume", $volume]);
	} else {
		$prefs->client($client)->set('lastVolume', $curVolume);
		main::DEBUGLOG && $log->is_debug && $log->debug("Saving last volume $curVolume for client '".$client->name()."'");
	}
}

sub powerOffClientsScheduler {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for scheduled power-off');
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
				main::INFOLOG && $log->is_info && $log->info('Current time '.parse_duration($currenttime).' = scheduled power-off time '.$powerOffTimeUnparsed.'. Powering off all players now.');
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
				main::INFOLOG && $log->is_info && $log->info(parse_duration($timeleft)." until next scheduled power-off at ".$powerOffTimeUnparsed);
				Slim::Utils::Timers::setTimer(undef, time() + $timeleft, \&powerOffClientsScheduler);
			}
		} else {
			$log->warn('powerOffTime = not defined or empty string');
		}
	}
}

sub initPLtoplevellink {
	main::DEBUGLOG && $log->is_debug && $log->debug('Started initializing playlist toplevel link.');
	# deregister item first
	Slim::Menu::BrowseLibrary->deregisterNode('PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST');

	# link to playlist in home menu
	my $toplevelplaylistname = $prefs->get('toplevelplaylistname') || 'none';
	main::DEBUGLOG && $log->is_debug && $log->debug('toplevelplaylistname = '.$toplevelplaylistname);
	if ($toplevelplaylistname ne 'none') {
		my $toplevelplaylistID = getPlaylistIDforName($toplevelplaylistname);
		main::DEBUGLOG && $log->is_debug && $log->debug('name of linked playlist (ID: '.$toplevelplaylistID.') = '.$toplevelplaylistname);

		Slim::Menu::BrowseLibrary->registerNode({
			type => 'link',
			name => 'PLUGIN_POTPOURRI_TOPLEVEL_LINKEDPLAYLIST_NAME',
			params => {'playlist_id' => $toplevelplaylistID},
			feed => \&Slim::Menu::BrowseLibrary::_playlistTracks,
			icon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			jiveIcon => 'plugins/PotPourri/html/images/browsemenupfoldericon.png',
			condition => \&Slim::Menu::BrowseLibrary::isEnabledNode,
			id => 'PTP_HOMEMENU_TOPLEVEL_LINKEDPLAYLIST',
			weight => 79,
			cache => 0,
		});
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished initializing playlist toplevel link.');
}


sub APCquery {
	my ($trackURLmd5, $queryType) = @_;
	return if (!$trackURLmd5 || !$queryType);
	my $dbh = Slim::Schema->dbh;
	my $returnVal;
	my $sql = "select ifnull($queryType, 0) from alternativeplaycount where urlmd5 = \"$trackURLmd5\"";
	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_columns(undef, \$returnVal);
	$sth->fetch();
	$sth->finish();
	main::DEBUGLOG && $log->is_debug && $log->debug('Current APC '.$queryType.' for trackurlmd5 ('.$trackURLmd5.') = '.$returnVal);
	return $returnVal;
}

sub getTrackIdForContextMenu {
	my ($client, $url, $track) = @_;
	if ($track->id) {
		return {
			type => 'text',
			name => 'Track ID: '.$track->id,
			itemvalue => $track->id,
			itemid => $track->id,
		};
	} else {
		return;
	}
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
		main::DEBUGLOG && $log->is_debug && $log->debug("Playlist '".$playlistname."' exists.");
		my $PLloop = $queryresult->getResult('playlists_loop');
		foreach my $playlist (@{$PLloop}) {
			$playlistid = $playlist->{id};
		}
	return $playlistid || '' ;
	} else {
		$log->warn("Couldn't find selected playlist to link to.")
	}
}

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	my $thisdir;
	foreach $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
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

sub getDisplayName {'PLUGIN_POTPOURRI'}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
