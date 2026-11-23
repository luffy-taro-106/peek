#!/usr/bin/perl
# Usage: /usr/bin/perl peek-mediaremote.pl /path/PeekMediaRemote.dylib stream|send
use strict;
use warnings;
use DynaLoader;
my ($lib, $mode) = @ARGV;
my $fn = ($mode // 'stream') eq 'send' ? 'peek_mr_send' : 'peek_mr_stream';
my $h = DynaLoader::dl_load_file($lib, 0) or die "load failed: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($h, $fn) or die "symbol missing: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub('main::peek_entry', $sym);
peek_entry();
