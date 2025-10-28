#!/bin/bash

echo "This is a pause test. Press ENTER to continue."
read
echo "You pressed Enter. Script continues."

echo "Do you want to delete test.txt? [y/N]"
read -r DELETE
if [[ "$DELETE" == "y" || "$DELETE" == "Y" ]]; then
    echo "Would delete file here."
else
    echo "No deletion."
fi