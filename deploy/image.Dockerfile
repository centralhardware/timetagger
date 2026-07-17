# Dockerfile that is simply based on the published Docker image.
#
# Some MyPaas args (ignore if you don't use MyPaas):
#
# mypaas.service = timetagger.test1
# mypaas.url = https://test1.timetagger.app
# mypaas.maxmem = 256m

FROM ghcr.io/centralhardware/timetagger
