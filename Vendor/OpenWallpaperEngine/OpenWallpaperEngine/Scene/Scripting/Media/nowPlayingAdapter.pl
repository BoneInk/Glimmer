#!/usr/bin/perl
# Open Wallpaper Engine's Now Playing adapter (NowPlayingAdapter.swift runs it).
#
# From macOS 15.4, MediaRemote answers only Apple's own processes: clients whose bundle id starts
# with "com.apple.". /usr/bin/perl is one (mediaremoted sees it as com.apple.perl5), and the
# system perl ships Apple's PerlObjCBridge, which messages Objective-C classes. So this script
# runs in /usr/bin/perl, reads the session through MediaRemote's own classes and streams it to the
# app. Nothing is compiled or installed.
#
# The technique of borrowing /usr/bin/perl's access comes from mediaremote-adapter by Jonas van
# den Berg and contributors (https://github.com/ungive/mediaremote-adapter, BSD 3-Clause License),
# after a finding by Mx-Iris. None of its code is used here: it loads a compiled framework through
# DynaLoader, this script uses PerlObjCBridge.
#
# Output on stdout, one line per change:
#   S <base64 binary property list>  the session: MediaRemote's now-playing dictionary, only the
#                                    keys the app reads, plus "isPlaying", the playing app's
#                                    "sessionBundleIdentifier" and, for an item without artwork,
#                                    "playerBundleIdentifier"; empty when nothing plays
#   E <reason>                       a fatal error; the script then exits with status 1
# It exits when stdin closes (the app quit or crashed) and on SIGTERM.
use strict;
use warnings;
use IO::Select;

$| = 1;

sub fail {
    my ($reason) = @_;
    $reason =~ s/\s+/ /g;
    print "E $reason\n";
    exit 1;
}

eval { require Foundation; 1 } or fail("PerlObjCBridge is unavailable: $@");
# An Objective-C exception returns undef instead of ending the script.
PerlObjCBridge::setDieOnExceptions(0);

sub string { NSString->stringWithUTF8String_($_[0]) }
sub present { my ($object) = @_; return defined($object) && ref($object) && ${$object}; }

my $bundle = NSBundle->bundleWithPath_('/System/Library/PrivateFrameworks/MediaRemote.framework');
fail('MediaRemote.framework is missing') unless present($bundle) && $bundle->load;
for my $class (qw(MRNowPlayingRequest MRMediaRemoteServiceClient)) {
    fail("MediaRemote has no $class") unless present($bundle->classNamed_($class));
    no strict 'refs';
    @{"${class}::ISA"} = ('PerlObjCBridge');
}

my @KEYS = map { string("kMRMediaRemoteNowPlayingInfo$_") }
    qw(Title Artist Album AlbumArtist Genre MediaType Duration ElapsedTime Timestamp PlaybackRate ArtworkData);
my $ARTWORK = string('kMRMediaRemoteNowPlayingInfoArtworkData');
my $IS_PLAYING = string('isPlaying');
# Sent only for an item without artwork of its own: the app playing it, whose icon the app shows
# as the thumbnail instead, as the menu bar's Now Playing does.
my $PLAYER = string('playerBundleIdentifier');
my $SESSION_PLAYER = string('sessionBundleIdentifier');

# The artwork. Most players (Music among them) don't put the image in the now-playing item; its
# metadata only says one is available, and MediaRemote sends the image to a client that asks for
# it at a size: a now-playing controller whose playback-queue request names one. One controller
# runs per item; once loaded, its response's queue holds the item with its artwork. Without these
# classes the session is sent without artwork.
my $ARTWORK_SIZE = 600; # MRPlaybackQueueRequest's defaultArtworkWidth and defaultArtworkHeight
my $artworkRequests = 1;
for my $class (qw(MRNowPlayingController MRNowPlayingControllerConfiguration MRPlaybackQueueRequest MRDestination)) {
    if (!present($bundle->classNamed_($class))) {
        print STDERR "MediaRemote has no $class; now-playing artwork is only read when the player includes it\n";
        $artworkRequests = 0;
        last;
    }
    no strict 'refs';
    @{"${class}::ISA"} = ('PerlObjCBridge');
}
my ($artworkController, $artworkItem) = (undef, '');
# The item has artwork that hasn't loaded yet, so the session is read again on the next tick.
my $artworkPending = 0;

sub identifier {
    my ($item) = @_;
    my $identifier = $item->identifier;
    return present($identifier) ? $identifier->UTF8String : '';
}

# The item's artwork from a controller that requests it, or undef while it loads or has none.
sub requestedArtwork {
    my ($item) = @_;
    return undef unless $artworkRequests;
    my $metadata = $item->metadata;
    return undef unless present($metadata) && $metadata->artworkAvailable;
    my $id = identifier($item);
    if ($id ne $artworkItem || !present($artworkController)) {
        $artworkController->endLoadingUpdates if present($artworkController);
        my $request = MRPlaybackQueueRequest->defaultPlaybackQueueRequest;
        $request->setArtworkWidth_($ARTWORK_SIZE);
        $request->setArtworkHeight_($ARTWORK_SIZE);
        my $configuration = MRNowPlayingControllerConfiguration->alloc->initWithDestination_(MRDestination->localDestination);
        $configuration->setPlaybackQueueRequest_($request);
        $configuration->setRequestPlaybackQueue_(1);
        $artworkController = MRNowPlayingController->alloc->initWithConfiguration_($configuration);
        $artworkController->beginLoadingUpdates;
        $artworkItem = $id;
    }
    $artworkPending = 1;
    my $response = $artworkController->response;
    my $queue = present($response) && $response->respondsToSelector_('playbackQueue') ? $response->playbackQueue : undef;
    my $items = present($queue) ? $queue->contentItems : undef;
    return undef unless present($items);
    for my $index (0 .. $items->count - 1) {
        my $queued = $items->objectAtIndex_($index);
        next unless identifier($queued) eq $id;
        my $artwork = $queued->artwork;
        my $data = present($artwork) ? $artwork->imageData : undef;
        $artworkPending = 0 if present($data);
        return $data;
    }
    return undef;
}

# Whether the item says it has artwork (loaded or still loading).
sub itemHasArtwork {
    my ($item) = @_;
    return 0 unless $item->respondsToSelector_('metadata');
    my $metadata = $item->metadata;
    return present($metadata) && $metadata->respondsToSelector_('artworkAvailable') && $metadata->artworkAvailable;
}

# The bundle id of the app playing (the parent app's for a helper process, such as a browser's
# media process), or undef.
sub playerBundleIdentifier {
    return undef unless MRNowPlayingRequest->respondsToSelector_('localNowPlayingPlayerPath');
    my $path = MRNowPlayingRequest->localNowPlayingPlayerPath;
    my $client = present($path) && $path->respondsToSelector_('client') ? $path->client : undef;
    return undef unless present($client);
    for my $selector (qw(parentApplicationBundleIdentifier bundleIdentifier)) {
        next unless $client->respondsToSelector_($selector);
        my $identifier = $client->$selector;
        return $identifier if present($identifier) && $identifier->length > 0;
    }
    return undef;
}

# The session as one line (without the "S "), or undef when it can't be read.
sub session {
    $artworkPending = 0;
    my $out = NSMutableDictionary->dictionary;
    my $item = MRNowPlayingRequest->localNowPlayingItem;
    if (present($item)) {
        my $info = $item->nowPlayingInfo;
        if (present($info)) {
            for my $key (@KEYS) {
                my $value = $info->objectForKey_($key);
                $out->setObject_forKey_($value, $key) if present($value);
            }
        }
        if (!present($out->objectForKey_($ARTWORK)) && $item->respondsToSelector_('artwork')) {
            my $artwork = $item->artwork;
            my $data = present($artwork) ? $artwork->imageData : undef;
            $out->setObject_forKey_($data, $ARTWORK) if present($data);
        }
        if (!present($out->objectForKey_($ARTWORK))) {
            my $data = requestedArtwork($item);
            $out->setObject_forKey_($data, $ARTWORK) if present($data);
        }
        my $player = playerBundleIdentifier();
        if (present($player)) {
            $out->setObject_forKey_($player, $SESSION_PLAYER);
            $out->setObject_forKey_($player, $PLAYER) if !present($out->objectForKey_($ARTWORK)) && !itemHasArtwork($item);
        }
        $out->setObject_forKey_(NSNumber->numberWithBool_(MRNowPlayingRequest->localIsPlaying ? 1 : 0), $IS_PLAYING);
    }
    # 200: NSPropertyListBinaryFormat_v1_0, which keeps dates to the sub-second.
    my $data = NSPropertyListSerialization->dataWithPropertyList_format_options_error_($out, 200, 0, undef);
    return undef unless present($data);
    return $data->base64EncodedStringWithOptions_(0)->UTF8String;
}

my $last = '';
sub emit {
    my $line = eval { session() };
    if (!defined $line) {
        print STDERR 'Now Playing could not be read' . ($@ ? ": $@" : '') . "\n";
        return;
    }
    return if $line eq $last;
    $last = $line;
    print "S $line\n";
}

# The notification observer. PerlObjCBridge answers only selectors whose signature it knows, so
# the handler takes the name of a known one with the same signature (void, one object argument).
package OWENowPlayingObserver;
our @ISA = ('PerlObjCBridge');
sub new { my $unused = 0; return bless \$unused, shift; }
sub postNotification_ { main::emit(); }
package main;
PerlObjCBridge::preloadSelectors('NSNotificationCenter');

my $observer = OWENowPlayingObserver->new;
my $center = NSNotificationCenter->defaultCenter;
for my $name (qw(kMRMediaRemoteNowPlayingInfoDidChangeNotification
                 kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification
                 kMRMediaRemoteNowPlayingApplicationDidChangeNotification)) {
    $center->addObserver_selector_name_object_($observer, 'postNotification:', string($name), undef);
}

# MediaRemote posts those notifications on the queue it is given; the main queue runs in the run
# loop below. Without notifications the session is read once a second instead, and so it is while
# the item's artwork loads (no notification says when it has).
my $registered = 0;
my $service = MRMediaRemoteServiceClient->sharedServiceClient;
my $client = present($service) ? $service->notificationClient : undef;
if (present($client)) {
    $client->registerForNowPlayingNotificationsWithQueue_(NSOperationQueue->mainQueue->underlyingQueue);
    $registered = $client->isRegisteredForNowPlayingNotifications ? 1 : 0;
}
print STDERR "Now Playing notifications are unavailable; reading the session once a second\n" unless $registered;

emit();

my $runLoop = NSRunLoop->currentRunLoop;
$runLoop->addPort_forMode_(NSPort->port, string('kCFRunLoopDefaultMode')); # keeps the run loop waiting
my $stdin = IO::Select->new(\*STDIN);
my $parent = getppid();
while (1) {
    $runLoop->runMode_beforeDate_(string('kCFRunLoopDefaultMode'), NSDate->dateWithTimeIntervalSinceNow_(1));
    if ($stdin->can_read(0)) {
        my $buffer;
        exit 0 unless sysread(STDIN, $buffer, 4096);
    }
    exit 0 if getppid() != $parent;
    emit() if !$registered || $artworkPending;
}
