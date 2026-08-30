#!/usr/bin/perl
# SoftwareArchive 按键读取助手（macOS 自带 perl，无第三方依赖）
# 以 cbreak 模式持有终端，把按键解析成 token 后逐行写入 stdout，
# 主程序通过管道逐行读取。作用：消除 bash 3.2 read -t 只支持整秒、
# 单独按 Esc 需等待 1 秒才能与转义序列区分开的交互延迟。
use strict;
use warnings;
use IO::Select;

$| = 1;

# 保存并切换终端模式：保留 ISIG（Ctrl+C 仍产生 SIGINT），关闭回显与行缓冲
my $saved = qx(stty -g <&0 2>/dev/null);
chomp $saved if defined $saved;
if (defined $saved && $saved ne '') {
    system("stty -icanon -echo min 1 time 0 <&0 2>/dev/null");
}

sub restore_tty {
    if (defined $saved && $saved ne '') {
        system("stty $saved <&0 2>/dev/null");
    }
}
$SIG{TERM} = sub { restore_tty(); exit 0 };
$SIG{INT}  = sub { restore_tty(); exit 130 };
$SIG{PIPE} = sub { restore_tty(); exit 0 };
END { restore_tty() }

my $sel = IO::Select->new(\*STDIN);

sub read_byte {   # 带超时（秒，可小数）读一个字节；超时或 EOF 返回 undef
    my ($timeout) = @_;
    return undef unless $sel->can_read($timeout);
    my $b;
    my $n = sysread(STDIN, $b, 1);
    return undef unless defined $n && $n > 0;
    return $b;
}

my $csi = { 'A' => 'UP', 'B' => 'DOWN', 'C' => 'RIGHT', 'D' => 'LEFT',
            'H' => 'HOME', 'F' => 'END' };

while (1) {
    my $c = read_byte(undef);          # 无限等待首个字节
    last unless defined $c;

    if ($c eq "\x1b") {                # Esc 或转义序列
        my $n = read_byte(0.04);       # 序列后续字节与首字节同时到达，40ms 足矣
        if (!defined $n) { print "ESC\n"; next; }
        if ($n eq '[') {
            my $f = read_byte(0.1);
            next unless defined $f;
            if ($f eq '1' || $f eq '7' || $f eq '4' || $f eq '8' || $f eq '3') {
                my $t = read_byte(0.1);
                next unless defined $t && $t eq '~';
                print "HOME\n"   if $f eq '1' || $f eq '7';
                print "END\n"    if $f eq '4' || $f eq '8';
                print "DELETE\n" if $f eq '3';
            } elsif (exists $csi->{$f}) {
                print "$csi->{$f}\n";
            }
            next;
        }
        if ($n eq 'O') {               # 应用模式光标键（如 ESC O A）
            my $f = read_byte(0.1);
            next unless defined $f;
            print "$csi->{$f}\n" if exists $csi->{$f};
            next;
        }
        next;                          # 其它未知序列：吞掉
    }
    if ($c eq "\r" || $c eq "\n")      { print "ENTER\n";     next; }
    if ($c eq ' ')                     { print "SPACE\n";     next; }
    if ($c eq "\x7f" || $c eq "\x08")  { print "BACKSPACE\n"; next; }
    if ($c eq "\x01")                  { print "HOME\n";      next; }
    if ($c eq "\x05")                  { print "END\n";       next; }
    if ($c eq "\x04")                  { print "DELETE\n";    next; }
    if ($c eq "\x15")                  { print "CLEAR\n";     next; }
    my $ord = ord($c);
    if ($ord < 0x20)                   { next; }   # 其余控制字符忽略
    if ($ord >= 0xC2 && $ord <= 0xF4) {          # UTF-8 多字节字符
        my $need = $ord >= 0xF0 ? 3 : $ord >= 0xE0 ? 2 : 1;
        my $s = $c;
        for (1 .. $need) {
            my $b2 = read_byte(0.1);
            last unless defined $b2;
            $s .= $b2;
        }
        print "CHAR:$s\n";
        next;
    }
    print "CHAR:$c\n";
}
restore_tty();
