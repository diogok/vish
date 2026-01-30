#!/bin/sh

wrk -c100 -t8 -d10 -H 'Connection: Keep-Alive' http://localhost:8080/
#wrk -c100 -t8 -d10 http://localhost:8080/
