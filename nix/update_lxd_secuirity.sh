
lxc config device add mk8s kmsg unix-char source=/dev/kmsg path=/dev/kmsg
lxc config set mk8s linux.kernel_modules ip_tables,ip6_tables,nf_nat,overlay,br_netfilter
lxc config set nk8s security.nesting true
lxc config set nk8s security.privileged true
