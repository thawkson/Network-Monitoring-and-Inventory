#!/bin/bash
#echo -n "Downloadling MAC ADDRESS Table from IEEE Standards"
#wget -x http://standards.ieee.org/regauth/oui/oui.txt .
grep "(hex)" oui.txt | awk '{print $1","$3}' | sed 's/\-/\:/g'
