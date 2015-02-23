{ config, pkgs, ... }:

with pkgs.lib;
let
  duplicityBackup = pkgs.writeScript "backup-duplicity" ''
    #! /bin/sh
    echo "Starting backups"
    export PATH=$PATH:/var/run/current-system/sw/bin
    time duplicity --full-if-older-than 30D --no-encryption /data/pt-wiki file:///backup/cartman/pt-wiki
    time duplicity --no-encryption --force remove-all-inc-of-but-n-full 1 file:///backup/cartman/pt-wiki

    time duplicity --full-if-older-than 30D --no-encryption /data/subversion file:///backup/cartman/subversion
    time duplicity --no-encryption --force remove-all-inc-of-but-n-full 1 file:///backup/cartman/subversion

    time duplicity --full-if-older-than 30D --no-encryption /data/subversion-ptg file:///backup/cartman/subversion-ptg
    time duplicity --no-encryption --force remove-all-inc-of-but-n-full 1 file:///backup/cartman/subversion-ptg

    time duplicity --full-if-older-than 30D --no-encryption /data/subversion-strategoxt file:///backup/cartman/subversion-strategoxt
    time duplicity --no-encryption --force remove-all-inc-of-but-n-full 1 file:///backup/cartman/subversion-strategoxt

    echo Done
  '';

in
{
  imports = [ ./build-machines-dell-r815.nix ./delft-webserver.nix ./sysstat.nix ./datadog.nix ];

  fileSystems."/backup" =
    { device = "130.161.158.5:/dxs/users4/group/buildfarm";
      fsType = "nfs4";
    };

  services.dd-agent.postgresqlConfig = ''
    init_config:

    instances:
       -   host: localhost
           port: 5432
           username: datadog
           password: ${builtins.readFile ./datadog.secret}
  '';

  services.postgresqlBackup = {
    enable = true;
    databases = [ "hydra" ];
  };

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    package = pkgs.postgresql92;
    dataDir = "/data/postgresql";
    extraConfig = ''
      log_min_duration_statement = 5000
      log_duration = off
      log_statement = 'none'
      max_connections = 250
      work_mem = 16MB
      shared_buffers = 4GB
      # Checkpoint every 256 MB.
      checkpoint_segments = 16
      # We can risk losing some transactions.
      synchronous_commit = off
      effective_cache_size = 24GB
    '';
    authentication = ''
      host  all        all       131.180.119.77/32 md5
      host  hydra      hydra     131.180.119.73/32 md5
      host  hydra_test hydra     131.180.119.73/32 md5
      host  zabbix     zabbix    131.180.119.73/32  md5
    '';
  };

  # Bump kernel.shmmax for PostgreSQL. FIXME: this should be a NixOS
  # option around systemd-sysctl.
  system.activationScripts.setShmMax =
    ''
      ${pkgs.procps}/sbin/sysctl -q -w kernel.shmmax=$((6 * 1024**3))
    '';

  services.zabbixAgent.extraConfig = ''
    UserParameter=hydra.evaluations.timesincelast,${pkgs.postgresql}/bin/psql hydra -At -c 'select round(EXTRACT(EPOCH FROM now()) - timestamp) from jobsetevals order by id desc limit 1'
    UserParameter=hydra.queue.total,${pkgs.postgresql}/bin/psql hydra -At -c 'select count(*) from builds where finished = 0'
    UserParameter=hydra.queue.building,${pkgs.postgresql}/bin/psql hydra -At -c 'select count(*) from builds where finished = 0 and busy = 1'
    UserParameter=hydra.queue.buildsteps,${pkgs.postgresql}/bin/psql hydra -At -c 'select count(*) from BuildSteps s join Builds i on s.build = i.id where i.finished = 0 and i.busy = 1 and s.busy = 1'
    UserParameter=hydra.builds,${pkgs.postgresql}/bin/psql hydra -At -c 'select count(*) from Builds'
  '';

  services.cron.systemCronJobs =
    [ "15 4 * * * root cp -v /var/backup/postgresql/* /backup/wendy/postgresql/  &> /var/log/backup-db.log"
      # Force the sixxs tunnel to stay alive by periodically
      # pinging the other side.  This is necessary to remain
      # reachable from the outside.
      "*/10 * * * * root ${pkgs.iputils}/sbin/ping6 -c 1 2001:610:600:88d::1"
      "40 2 * * *  root ${duplicityBackup} &>> /var/log/backup-duplicity.log"
    ];

  services.radvd.enable = false;
  services.radvd.config =
    ''
      interface ${config.system.build.mainPhysicalInterface} {
        AdvSendAdvert on;
        prefix 2001:610:685:1::/64 { };
        RDNSS 2001:610:685:1::1 { };
      };
    '';

  networking = {

    firewall.allowedTCPPorts = [ 80 443 10051 5432 5999 ];
    firewall.allowedUDPPorts = [ 53 67 ];
    /*
    firewall.extraCommands =
      ''
        iptables -A nixos-fw -p tcp --dport 5432 -i internal -j nixos-fw-accept
      '';
      */

    localCommands =
      ''
        # Cleanup.
        ip -6 route flush dev sixxs || true
        ip link set dev sixxs down || true
        ip tunnel del sixxs || true

        # Set up a SixXS tunnel for IPv6 connectivity.
        ip tunnel add sixxs mode sit local 131.180.119.77 remote 192.87.102.107 ttl 64
        ip link set dev sixxs mtu 1280 up
        ip -6 addr add 2001:610:600:88d::2/64 dev sixxs
        ip -6 route add default via 2001:610:600:88d::1 dev sixxs

        # Discard all traffic to networks in our prefix that don't exist.
        ip -6 route add 2001:610:685::/48 dev lo || true

        # Create a local network (prefix:1::/64).
        ip -6 addr add 2001:610:685:1::1/64 dev ${config.system.build.mainPhysicalInterface} || true

        # Forward traffic to our Nova cloud to "stan".
        #ip -6 route add 2001:610:685:2::/64 via 2001:610:685:1:222:19ff:fe55:bf2e || true
      '';

    dhcpcd.denyInterfaces = [ "sixxs" ];
  };

  # Needed for the Nixpkgs mirror script.
  environment.pathsToLink = [ "/libexec" ];
  environment.systemPackages = [ pkgs.dnsmasq pkgs.duplicity pkgs.db4 ];

  # Use cgroups to limit Apache's resources.
  systemd.services.httpd.serviceConfig.CPUShares = 1000;
  systemd.services.httpd.serviceConfig.MemoryLimit = "1500M";
  #systemd.services.httpd.serviceConfig.ControlGroupAttribute = [ "memory.memsw.limit_in_bytes 1500M" ];

  services.zabbixServer.enable = true;
  services.zabbixServer.dbServer = "wendy";
  services.zabbixServer.dbPassword = import ./zabbix-password.nix;

  # Poor man's time sync for the non-NixOS machines.
  /*
  systemd.services.fix-time =
    { path = [ pkgs.openssh ];
      script =
        ''
          ssh root@beastie "date $(date +'%Y%m%d%H%M.%S')" || true
          ssh root@demon "date $(date +'%Y%m%d%H%M.%S')" || true
        '';
      startAt = "*:03";
    };
  */

  services.logrotate.enable = true;
  services.logrotate.config = ''
    /var/log/httpd/access_log
    /var/log/httpd/error_log
    /var/log/httpd/access_log*.nl
    /var/log/httpd/error_log*.nl
    /var/log/httpd/access_log*.org
    /var/log/httpd/error_log*.org
    {
      daily
      dateext
      rotate 10000
      compress
      sharedscripts
      postrotate
        ${pkgs.coreutils}/bin/kill -HUP `${pkgs.coreutils}/bin/cat /var/run/httpd/httpd.pid`
      endscript
    }
  '';

  systemd.services.htcacheclean =
    { path = [  ];
      description = "Clean httpd Cache";
      serviceConfig.ExecStart =
        "${config.services.httpd.package}/bin/htcacheclean " +
        "-v -t -l 32G -p /var/cache/hydra-binary-cache";
      startAt = "Sat 05:45";
    };

  users.extraUsers.eelco =
    { description = "Eelco Dolstra";
      home = "/home/eelco";
      isNormalUser = true;
      openssh.authorizedKeys.keys = [ (import ../ssh-keys.nix).eelco ];
    };

  users.extraUsers.rbvermaa =
    { description = "Rob Vermaas";
      home = "/home/rbvermaa";
      isNormalUser = true;
      openssh.authorizedKeys.keys = [ (import ../ssh-keys.nix).rob ];
    };

}
