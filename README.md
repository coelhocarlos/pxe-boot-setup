# PXE-BOOT + Download automático de distros

Cria servidor PXE (**dnsmasq + tftpd-hpa + apache2 + ipxe**) no **Ubuntu 24.04**
em `192.168.0.200` e baixa as distros para a pasta `distros`.

## Distros

| Distro | Arquivo |
|---|---|
| Ubuntu Desktop 24.04.5.1 (amd64) | `ubuntu-24.04.5.1-desktop-amd64.iso` |
| Ubuntu Server 24.04.5 (amd64) | `ubuntu-24.04.5-live-server-amd64.iso` |
| Ubuntu Desktop 26.04.1 LTS (amd64) | `ubuntu-26.04.1-desktop-amd64.iso` |
| Ubuntu Server 26.04.1 LTS (amd64) | `ubuntu-26.04.1-live-server-amd64.iso` |
| Kali Linux 2026.2 Live/Desktop (amd64) | `kali-linux-2026.2-live-amd64.iso` |
| Windows 11 Enterprise Eval x64 (25H2) | `Windows11-x64-Eval.iso` |
| Windows 10 Enterprise Eval x64 (22H2) | `Windows10-x64-Eval.iso` |

Pasta de distros: **`/var/www/html/distros`** (servida em `http://192.168.0.200/distros/`).

> **Kali:** o ISO *live* da Kali é publicado **apenas via BitTorrent**
> (`KALI_LIVE_URL` aponta para o `.torrent`). O `02-download-isos.sh` baixa o
> torrent com `aria2c` e salva como `.iso`. Para boot PXE, o `03` extrai
> `live/vmlinuz` + `live/initrd.img` (TFTP) e `live/filesystem.squashfs` (HTTP,
> carregado com `boot=live fetch=...`).

## Requisitos

- Acesso SSH ao servidor: `192.168.0.200`, usuário **`pxeuser`**, senha **`1q2w3e!@`**
  (com permissão de `sudo`).
- Máquina local Linux/macOS: `sshpass`, `rsync`, `ssh` — ou Windows com `plink`/`pscp`.
- Servidor alvo: Ubuntu 24.04 limpo, ~12GB livres (só Ubuntu) ou ~40GB (com Windows).

> **DHCP (importante):** por padrão o dnsmasq roda em **proxy-DHCP**
> (`DHCP_PROXY=true`): ele **não** distribui IP/rota/DNS — apenas entrega as
> informações de boot PXE. Quem aloca os IPs é o DHCP do roteador. Assim não há
> conflito de DHCPs na LAN. Para o dnsmasq alocar IPs também, use
> `DHCP_PROXY=false` e ajuste `DHCP_RANGE` em `config-pxe.sh`.

## Opção 1) Deploy remoto automático (a partir deste repo)

```bash
chmod +x *.sh
./deploy-remote.sh            # envia arquivos + instala + baixa distros + cria menu
```

Etapas separadas (útil para retomar downloads):

```bash
./deploy-remote.sh install    # instala dnsmasq/tftp/apache/ipxe
./deploy-remote.sh download   # baixa as distros para $ISO_DIR
./deploy-remote.sh menu       # gera os menus PXE
```

### Windows (PowerShell, via plink/pscp do PuTTY)

O `deploy-remote.sh` precisa de `sshpass` (Linux/macOS). No Windows use:

```powershell
# baixe plink.exe e pscp.exe em C:\...\Temp\opencode\putty (ou passe -PuttyDir)
.\deploy-remote.ps1                 # tudo
.\deploy-remote.ps1 install
.\deploy-remote.ps1 download
.\deploy-remote.ps1 menu
```

## Opção 2) Rodar direto no servidor 192.168.0.200

```bash
ssh pxeuser@192.168.0.200
# copie a pasta pxe-boot para o servidor e então:
chmod +x *.sh
bash 01-install-pxe.sh        # instala e configura os serviços
bash 02-download-isos.sh      # baixa as distros (aceita: ubuntu | windows | all)
bash 03-setup-pxe-menu.sh     # extrai kernels/wimboot e gera menus
sudo bash validate.sh         # valida
```

## Apenas baixar as distros (script de download)

`02-download-isos.sh` baixa com retomada (`-c`), usa `aria2c` quando disponível
e verifica SHA256 do Ubuntu via `SHA256SUMS`:

```bash
bash 02-download-isos.sh            # tudo
bash 02-download-isos.sh ubuntu     # só Ubuntu Desktop + Server (24 + 26)
bash 02-download-isos.sh kali       # só Kali (via BitTorrent)
bash 02-download-isos.sh windows    # só Windows 10 + 11
```

## Testar PXE

- Clientes na mesma rede recebem IP via DHCP do roteador e as opções de boot via
  proxy-DHCP do dnsmasq (porta 67; PXE em 4011).
- **BIOS**: `pxelinux.0` → menu `pxelinux.cfg/default` (Linux + Windows).
- **UEFI**: `efi/ipxe.efi` → menu `boot/menu.ipxe` (Linux + Windows via `wimboot`).
- Ubuntu boota via **HTTP** (`casper url=http://.../distros/<iso>`): kernel/initrd
  saem do TFTP e o restante é lido do ISO por HTTP — **não usa NFS**.
- Windows usa `wimboot` carregando `boot.wim`/`BCD`/`boot.sdi` extraídos dos ISOs
  por HTTP.

## Limitações (LXC/Proxmox)

Se o servidor for um **container LXC** (ex.: `virt: lxc`), o `nfs-kernel-server`
não sobe (`/proc/fs/nfsd: permission denied`). Por isso o Ubuntu usa **HTTP**
em vez de NFS — funciona em LXC e em VM. TFTP é servido pelo `tftpd-hpa`
(porta 69) e o `dnsmasq` faz apenas DHCP/PXE.

## Ajustes

Edite `config-pxe.sh`:

- `PXE_IP`, `PXE_GW`, `PXE_DNS`, `PXE_IFACE` (`auto` detecta a interface de `PXE_IP`)
- `DHCP_PROXY` (`true` = proxy-DHCP; `false` = aloca IPs), `PXE_SUBNET`, `DHCP_RANGE`
- `SSH_HOST`, `SSH_USER`, `SSH_PASS`, `REMOTE_DIR`
- `ISO_DIR` (pasta de distros), URLs/nomes das distros
- `USE_ARIA2`, `ARIA2_CONNECTIONS`

## Observações sobre Windows

Os links do Evaluation Center da Microsoft usam caminhos com GUID fixo do CDN
(`software-static.download.prss.microsoft.com/dbazure/...`). Se um link expirar,
atualize `WIN10_URL`/`WIN11_URL` em `config-pxe.sh` ou baixe manualmente e coloque
a ISO em `$ISO_DIR` com o nome definido em `WINxx_ISO`.

## Reiniciar serviços

```bash
sudo systemctl restart dnsmasq
sudo systemctl restart apache2
sudo systemctl restart tftpd-hpa
```

## Serviços adicionais (Webmin / FTP / Samba)

| Serviço | Porta | Acesso |
|---|---|---|
| Webmin | `https://192.168.0.200:10000` | login `pxeuser` + senha do usuário |
| ProFTPD | `ftp://192.168.0.200` (21) | usuário `distros` / `1q2w3e!@` (home `/var/www/html/distros`) |
| Samba | `\\192.168.0.200\distros` (445) | leitura/escrita para todos na LAN (guest) |

- ProFTPD: `DefaultRoot ~` prende cada usuário na própria pasta. O usuário
  `distros` tem home em `/var/www/html/distros`.
- Samba: share `[distros]` com `guest ok = yes` e `force user/group = www-data`
  (arquivos novos ficam legíveis pelo Apache/PXE).
