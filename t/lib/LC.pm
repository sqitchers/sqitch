package LC;

our $TIME = do {
    if ($^O eq 'MSWin32') {
        require Win32::Locale;
        Win32::Locale::get_locale();
    } else {
        require POSIX;
        POSIX::setlocale( POSIX::LC_TIME() );
    }
};

# https://github.com/sqitchers/sqitch/issues/230#issuecomment-103946451
# https://rt.cpan.org/Ticket/Display.html?id=104574
$TIME = 'en_US_POSIX' if $TIME eq 'C.UTF-8';

1;
