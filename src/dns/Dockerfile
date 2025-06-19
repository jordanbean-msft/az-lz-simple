FROM coredns/coredns:1.12.2
EXPOSE 53 53/udp
COPY Corefile /opt/Corefile
ENTRYPOINT ["/coredns","-conf","/opt/Corefile"]
