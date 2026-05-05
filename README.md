# ansible-time-sync

## 安裝 Ansible（控制端, 若已安裝可忽略)
```
sudo apt update
sudo apt install -y ansible
ansible --version
```


Time Server 設定
## 請在 group_vars/all.yml 設定
```
chrony_time_servers:
  - "xxx.xxx.xxx.xxx"
```

執行
```
./run_time_sync.sh
```
