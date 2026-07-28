# ansible-time-sync

## 安裝 Ansible（控制端, 若已安裝可忽略)
```
sudo apt update
sudo apt install -y ansible
ansible --version
```

執行
```
./run_time_sync.sh --time-server 10.10.10.10 --time-zone Asia/Taipei
```

or
```
./run_time_sync.sh --user root --skip-ping --time-server 10.10.10.10 --time-zone Asia/Taipei
```
