

readme:
	perl -MPod::Markdown -e 'Pod::Markdown->new->filter(@ARGV)' lib/Parallel/Prefork/IPC.pm > README.md
