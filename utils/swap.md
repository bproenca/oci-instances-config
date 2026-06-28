### Add swap

```bash
sudo fallocate -l 2G /swapfile # if fallocate fails: sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
swapon --show && free -h # verify
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab # persist across reboots

echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swap.conf
sudo sysctl -p /etc/sysctl.d/99-swap.conf

swapon --show
free -h
```