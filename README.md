# server

先进行vnc链接 
连接网络或者也可以直接复制vnc.sh输入到vnc命令框中

```
ip link set eth0 up
udhcpc -i eth0
```
查看有没有IP地址
```
ip a
```
确认有 IP 后：

```
ping -c 3 github.com
```
能通即可。
运行一下脚本
```
busybox wget -O /tmp/vnc.sh https://raw.githubusercontent.com/7742-a/server/main/vnc.sh && sh /tmp/vnc.sh
```

等待电脑重启 alpine就安装完成了

