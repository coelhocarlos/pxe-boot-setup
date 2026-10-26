# Instalar Ubuntu Desktop em máquinas com 4 GB de RAM (SMB/CIFS)

Este é o método usado quando a máquina alvo tem **pouca RAM** (2–4 GB).
As entradas "ISO HTTP" (`url=...`) funcionam, mas só com 8–12 GB de RAM.

## Sintoma

A instalação começa, o kernel e o initrd carregam, a tela do instalador aparece
e o progresso **para por volta de 52%** (ou o kernel mata processos por falta de
memória). Em máquinas de 4 GB isso é esperado — não é bug de menu.

## Causa

Com `boot=casper netboot=url url=http://IP/distros/ubuntu-x.iso`, o casper chama
`do_urlmount()`, que:

1. baixa o **ISO inteiro** para dentro do initramfs (`/cow`, um `tmpfs` → RAM);
2. só então monta o ISO em loop e encontra o `casper/*.squashfs`.

| ISO | Tamanho | RAM necessária só para o download |
|---|---|---|
| Ubuntu 24.04.5.1 Desktop | 6.2 GB | ~6.5 GB+ |
| Ubuntu 26.04.1 Desktop | 6.5 GB | ~7 GB+ |

Com 4 GB o download não termina e a instalação trava em ~52%.

## Como a solução funciona

O ISO é **extraído uma única vez** para uma pasta (dentro da raiz web) e essa
pasta é exportada por **SMB/CIFS somente leitura**, sem senha:

```
cliente (initrd)  --CIFS-->  //192.168.0.110/pxe/ub26live-desktop
                              └── casper/minimal.squashfs  (lido sob demanda)
                              └── casper/minimal.standard.live.squashfs (instalador)
```

* O kernel monta o share com `netboot=cifs nfsroot=//IP/pxe/<pasta>`.
* O casper (`do_cifsmount`) roda `mount.cifs` com `-ouser=root,password=`.
* O `squashfs` **não é copiado**: só os blocos que o instalador pede são lidos
  pela rede. Uso de RAM fica em ~1 GB (funciona até com 2 GB).
* Nada de NFS: em LXC não privilegiado o `nfs-kernel-server` não sobe, e o
  casper não lê `nfsopts=` da linha de comando — por isso o share é SMB com
  convidado (`-ouser=root,password=`).

## Passo a passo

```bash
# no servidor PXE, com o repo já clonado
sudo bash 04-setup-pxe-cifs.sh
```

O script:

1. extrai cada ISO para `/var/www/html/distros/<pasta>` (se a pasta ainda não
   existir) usando `xorriso`, `mount -o loop` ou `7z`;
2. garante que a camada base se chama `casper/minimal.squashfs`
   (o 24.04 às vezes vem como `casper/filesystem.squashfs`);
3. cria o share `[pxe]` no Samba (convidado, somente leitura,
   `force user = nobody`) e ajusta `map to guest = Bad User`;
4. testa o login **do mesmo jeito que o initrd** (`smbclient -N -U root`);
5. gera as entradas iPXE em `/srv/tftp/boot/cifs.ipxe` e as insere no
   `menu.ipxe` (bloco `# >>> pxe-cifs items >>>`).

Depois escolha no menu:

```
[SMB] Ubuntu 26.04 Desktop (4GB RAM)
[SMB] Ubuntu 24.04 Desktop (4GB RAM)
```

## Linha de comando do kernel (o que realmente importa)

```text
ip=dhcp boot=casper netboot=cifs \
nfsroot=//192.168.0.110/pxe/ub26live-desktop \
ignore_uuid cloud-config-url=/dev/null cloud-init=disabled quiet splash
```

* `netboot=cifs` → `do_cifsmount`; **não** use `netboot=nfs`.
* `nfsroot=` → aqui é o caminho UNC `//servidor/share/pasta`
  (subpasta do share é aceita pelo `mount.cifs`).
* `ignore_uuid` → não tenta casar o UUID do ISO; obrigatório quando se usa pasta
  extraída (`matches_uuid` falharia).
* `cloud-init=disabled` → evita o cloud-init do live atrapalhar o instalador.
* **Não** passe `layerfs-path`: o casper monta **todas** as camadas
  `casper/*.squashfs`, igual ao boot pelo ISO.
* `---` é opcional no iPXE (as entradas HTTP usam, as SMB funcionam sem).

## Validação no servidor

Antes de ligar o cliente, os três comandos abaixo têm que funcionar:

```bash
# 1) share aparece
smbclient -N -U root //127.0.0.1/pxe -c 'ls'

# 2) o casper acha a camada base (ATENÇÃO: `ls` recebe MÁSCARA, não caminho)
smbclient -N -U root //127.0.0.1/pxe -c 'cd ub26live-desktop/casper; ls minimal.squashfs'

# 3) o kernel/initrd estão na raiz web
curl -sI http://127.0.0.1/distros/ub26live-desktop/casper/vmlinuz | head -1
curl -sI http://127.0.0.1/distros/ub26live-desktop/casper/initrd | head -1
```

Durante o boot do cliente:

```bash
watch -n2 'smbstatus -b; ss -tn | grep ":445"'
```

Deve aparecer uma sessão em `nobody`/`root` e a conexão do IP do cliente.

## Configuração do Samba usada

```ini
[global]
   map to guest = Bad User

[pxe]
   comment = Imagens PXE (somente leitura, convidado)
   path = /var/www/html/distros
   browseable = yes
   read only = yes
   guest ok = yes
   force user = nobody
```

`map to guest = Bad User` é o que faz o `mount.cifs -ouser=root,password=` do
casper entrar como convidado (o usuário `root` não existe no banco de senhas do
Samba). O share é somente leitura: o cliente nunca escreve no servidor.

## Problemas e soluções

| Sintoma no cliente | Causa | Correção |
|---|---|---|
| Instalação para em ~52% | `netboot=url` baixando o ISO inteiro para a RAM | usar `netboot=cifs` (este documento) |
| `nfsmount: //IP/pxe/...: need a server` | o mount CIFS falhou e o casper caiu no fallback NFS (que não entende caminho UNC) | o share/credencial está errado: rode os testes da seção *Validação* |
| `mount error(13): Permission denied` | `map to guest = never` ou share inexistente | `map to guest = Bad User` + `[pxe] guest ok = yes` |
| `mount error(2): No such file or directory` | pasta errada no `nfsroot=` ou share `[pxe]` não existe | conferir `//IP/pxe/<pasta>` |
| `Unable to find a live file system` / reinicia | `casper/minimal.squashfs` ausente ou com outro nome | renomear `filesystem.squashfs` → `minimal.squashfs` |
| Live sobe mas **não tem instalador** | faltou a camada `minimal.standard.live.squashfs` (no 26 o instalador NÃO está na base) | extrair o ISO completo, sem filtrar arquivos |
| `smbclient ... ls pasta/sub` mostra só a pasta pai | no smbclient o `ls` recebe máscara, não caminho (falso negativo) | `cd pasta/sub; ls` |
| `NT_STATUS_LOGON_FAILURE` | `map to guest` não aplicado ou `smbd` não reiniciou | `testparm -s`, `systemctl restart smbd` |
| Boot lento / "SMB2 negotiate failed" | servidor com `server min protocol = SMB3` e cliente antigo | deixar `server min protocol = SMB2` |

## iPXE Station (menu.json)

Se o servidor usa o **iPXE Station** (menu dinâmico em `/srv/ipxe/menu.json`),
a entrada equivalente é:

```json
{
  "name": "ubuntu26-desktop-smb",
  "title": "[SMB] Ubuntu 26.04 Desktop (4GB RAM)",
  "kernel": "boot/ubuntu26-desktop/vmlinuz",
  "initrd": "boot/ubuntu26-desktop/initrd",
  "cmdline": "ip=dhcp boot=casper netboot=cifs nfsroot=//192.168.0.110/pxe/ub26live-desktop ignore_uuid cloud-config-url=/dev/null cloud-init=disabled quiet splash",
  "description": "Le o squashfs por SMB sob demanda. Serve para 2-4 GB de RAM.",
  "enabled": true,
  "order": 5,
  "entry_type": "boot",
  "boot_mode": "custom"
}
```

O `kernel`/`initrd` podem vir da própria pasta extraída
(`http://IP/distros/<pasta>/casper/vmlinuz|initrd`): são idênticos aos extraídos
para o TFTP (conferido com `cmp`).

## Espaço em disco

Além do ISO, a pasta extraída ocupa praticamente o mesmo tamanho:

| Distro | ISO | Pasta extraída |
|---|---|---|
| Ubuntu 24.04.5.1 Desktop | 6.2 GB | ~6.2 GB |
| Ubuntu 26.04.1 Desktop | 6.5 GB | ~6.5 GB |

Se quiser economizar, remova o ISO depois de validar a pasta (ela é a mídia de
instalação). **Não** remova as pastas `ub26live-desktop` / `ub24live-desktop`.

## Reverter

O `04` faz backup do Samba antes de mexer:

```bash
ls -t /etc/samba/smb.conf.bak-* | head -1
sudo cp /etc/samba/smb.conf.bak-AAAAAMMDD-HHMMSS /etc/samba/smb.conf
sudo systemctl restart smbd
```

## Notas

* Testado com Samba 4.19 (Ubuntu 24.04), `security = user`,
  `server min protocol = SMB2`, cliente = initrd do Ubuntu 24.04.5 e 26.04.1.
* O `cifs.ko` e o `/sbin/mount.cifs` já vêm nos initrds do desktop (24 e 26),
  junto com as dependências (`nls_ucs2_utils`, `netfs`, `cifs_md4`). Não é
  preciso remasterizar initrd.
* Em LXC não privilegiado, NFS com kernel é impossível (`/proc/fs/nfsd:
  permission denied`); CIFS funciona normalmente.
* Funciona também com VM e máquina física, desde que a rede do cliente alcance
  a porta 445 do servidor.
