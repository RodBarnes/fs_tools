#!/usr/bin/env bash

sudo chown root:root fs_shared.sh
sudo mv fs_shared.sh /usr/local/lib

sudo chown root:root fs_*.sh
sudo chmod +x fs_*.sh
for file in fs_*.sh; do
	sudo mv "$file" "/usr/local/bin/${file%.sh}"
done
