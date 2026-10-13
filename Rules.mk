# Root Rules.mk. SUBDIRS must name IMMEDIATE children only - TOBi walks the
# tree one level at a time, so "src/dspf" here fails with a KeyError on 'src'.
SUBDIRS = src
