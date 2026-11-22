# WING Compact T55: manueller Fabric-Identitätstest

**Offline gebaut. Keine Board- oder Startfreigabe. Kein Update, kein Flash.**

Dies ist die Stufe **nach** passiver Linux-Inventur und **vor** Audioqualifikation. Sie prüft genau fünf Identitätswörter über SS1, nicht Audio. Das getrennte RAM-FIT enthält Kernel, DTB, Initramfs, Loader und exakt dessen Manifest/Bitstream. Es enthält keinen Stock-Wrapper, keinen Produktloader, OMC, DSP-Payload, Clock-Setter oder USB-Login. Es gibt keinen FPGA-Autoload. Nicht mit `0x2bcf0718` starten: dieses B-Audio-Design gibt den gemeinsamen PHY-Reset W9 frei.

## Zuerst: bestehendes Linux per SSH, ohne Neustart

Am laufenden OpenWING zunächst nur Inventur erheben. Diese Befehle lesen Dateien bzw. listen Knoten; sie öffnen kein SPI/GPIO-Zeichengerät:

```sh
uname -a
cat /proc/cmdline
dt=/sys/firmware/devicetree/base
tr '\000' '\n' < "$dt/model"
spi=$(tr -d '\000' < "$dt/aliases/spi1")
printf 'spi1: %s\n' "$spi"
ls -ld "$dt$spi" /sys/bus/spi/devices/spi* /dev/spibone* /dev/spidev* 2>/dev/null
for node in "$dt$spi"/*@*; do
    [ -f "$node/compatible" ] || continue
    printf '%s: ' "$node"; tr '\000' '\n' < "$node/compatible"
done
for node in /sys/bus/spi/devices/spi*; do
    [ -e "$node" ] || continue
    readlink "$node/driver" || :
    [ ! -r "$node/state" ] || cat "$node/state"
done
```

Fehlende Informationen bleiben unbekannt. Ein vorhandenes `/dev/spibone0` oder `offline` ist **kein** Identitäts- oder Isolationstest. Der eingecheckte OpenWING-USB-Konsolen-DT (`8b9e99a5…`) hat an ECSPI2 nur `fpga@0`/`rohm,dh2228fv`, `cs-gpios = <0>`, keine korrekte SS1-Bindung. Das separate passive Diagnoseimage hat gar keine SPI-Kinder, keine ECSPI2-Pads und keinen passenden Treiber. Selbst der neuere Produkt-SPIBone-DT allein genügt nicht: Der Produktkernel verlangt Caps `0x0f`, der Bench `0x00`; der Produktloader akzeptiert kein Benchmanifest. Keine Erkennung dieses Profils durch Laufzeit-Pinmux, DT-Overlay, `driver_override`, `bind/unbind`, `/dev/mem`, `kexec` oder Erzwingen von `online` nachrüsten. Der laufenden Installation nichts hinzufügen. Ohne belegten vertrauenswürdigen RAM-Startweg, der das FIT unverändert akzeptiert, endet der Test hier. Kein Update, kein `saveenv`, kein Abschalten einer Bootprüfung.

## Elektrische Stop-Kriterien (vor dem Bench-Boot)

**Konfiguration ≠ User-Mode.** Laut Efinity User Guide 2026.1, S. 163 („Release Tri-States before Reset“), darf man während Konfiguration nicht auf Fabric-Ausgangswerte bauen. CRESET entfernt auch die Wirkung der vorherigen Fabric. Dedizierte/duale Konfigurationspins sind davon zu unterscheiden; CDONE signalisiert den Konfigurationsfortschritt, nicht die elektrische Isolation. Auch Boot-ROM/U-Boot, ein voriges FPGA-Image, SoC-Pad-Remux beim Linux-Probe, ein abgebrochener Transfer und die Rückkehr in die Stock-Firmware sind vom finalen P&R-Pinbericht nicht erfasst.

Nur an einem hierfür qualifizierten, strom-/pegelüberwachten Aufbau weitergehen:

1. **Sämtliche Netze gegen Boardrevision, Besitzer, Spannung, Pulls und Richtung abgleichen**, vom Einschalten über Boot, CRESET, passive x1 bis User-Mode/Abbruch/Ausschalten. `gateware/outflow/wing-fpga.pinout.csv` inventarisiert alle 484 Balls; `board-pins.tsv` nennt die 17 zugewiesenen Fabric-Pads. Prüfen: unbenutzte User-Pads haben im finalen Efinity-Setup schwachen Pull-up (keine aktiven Ausgänge), dedizierte DDR-/JTAG-/Konfigurations- und Versorgungspins haben separate Rollen. A9, T6 und R7 sind explizit Eingänge ohne Pull im User-Mode; **DSP3 ist nicht als im Reset bestätigt**. Für alle nicht eindeutig zugeordneten Boardnetze muss der Aufbau nachweisen, dass Bias, Umstecken der Pinrollen und eventuelle fremde Treiber keine falsche Aktivierung, Überstrom oder Kontention auslösen. Unbekannt bedeutet Stopp.
2. **Isolation muss extern gelten**, auch wenn W9/U12/B14/A2 vor CDONE oder bei Abbruch nicht getrieben werden. W9 hält beide PHYs erst im User-Mode im Reset; U6/T4/AA12 sind dann konstant low. Prüfen, dass genau diese sieben Netze beim Umschalten nie gegen einen Push-Pull-Treiber arbeiten. Bestehende oder nachweislich konfliktfreie externe Isolation für PHY A/B, Sync-Treiber, DSPs und Konverter/Mute voraussetzen; A9 nicht treiben; Audiowege und AES50-Peers extern trennen. Leitungen nicht blind nach Masse oder Versorgung ziehen. Software-Replay oder `offline=yes` ersetzt die elektrische Isolation nicht.
3. **SPI/Boot-Pads messen:** J2/SS0 und V6/SS1 beide idle high und im vollständigen Konfigurationsupload inaktiv; beim anschließenden Read nur SS1 low. W1/CCK und V2/CDI0 sind Eingänge zum FPGA, der i.MX fährt sie im passenden Modus; V1/CDI1/MISO muss auf SoC-Seite Eingang und ohne fremden Gegentreiber sein (User-Mode: FPGA-OE nur SS1 aktiv bei SS0 high). V3/SS_N, CSI/V6, CBUS1/U6, CBUS2/T4 und übrige duale Pins gegen tatsächliche passive-x1-Straps und Leitungstreiber prüfen. CRESET_N an V4 aktiv low (GPIO2_17), CDONE an V5 nur beobachten (GPIO4_26); Bias und Eigentum vor/nach GPIO-Request verifizieren. SoC-Padgruppenzuordnung ist im Bench-DTB geprüft, reale Bootpegel nicht.
4. **Clock separat messen:** Si5351 CLK0 → R2 muss vor dem Lesen stabil 49,152 MHz mit gültigem Pegel und Duty-Cycle liefern. SCK ist separat, Mode 0, höchstens 2 MHz. Der FPGA hat keine automatische Clock-Programmierung und keinen Lock-Nachweis; `READY=1` wird nur bei funktionierendem fabricgetakteten SPIBone lesbar. CLK5/M3, AB15, PLL, RMII, SPORT und AES-Sync werden nicht benutzt/qualifiziert. Bei fehlendem/falschem R2 nicht laden oder am Clock-Setup experimentieren.

## Später: ein manueller Versuch im passenden Bench-FIT

1. `shasum -a 256 -c SHA256SUMS` im Paketverzeichnis. Nur `linux/wing-t55-fabric-id.itb` für einen zuvor bestätigten, zugelassenen RAM-only-Bootweg verwenden. FIT-Konfiguration `wing`, Init `/init`; die FIT-Load-Adressen sind 0x12000000/0x13000000/0x13800000. Die Verfügbarkeit eines solchen Bootwegs am konkreten Gerät ist **nicht** belegt. Kein `.wingfw` für diesen Test und kein Bootbefehl für unbekannte Infrastruktur. Weitere Checks nur nach separater Boardfreigabe.
2. Am Mac mit dem kopierten **unveränderten** OpenWING-Recorder `python3 openwing-inputs/tools/wing-t55-diag/record.py --list` den neuen Linux-CDC-Port (USB-B, `0525:a4a7`) finden. `python3 openwing-inputs/tools/wing-t55-diag/record.py --port /dev/cu.usbmodem…` mit genau diesem Port starten. Nicht das ggf. kurz sichtbare U-Boot-ACM auswählen. Vor Auslösung `WING_DIAG_V1` mit `profile=fabric-id-manual` und der erwarteten Linux-Build-ID (siehe `fit-verify.log`), SPI-Geräten `spi1.0`/`spi1.1` sowie `WING_FABRIC_ID_V1 event=preflight ss1_state=offline transport_ready=yes attempted=no` verlangen. `spidev1.1` darf nicht vorhanden sein. U-Boot und frühes Linux sind im USB-Log nicht sichtbar; bei fehlendem Block oder Abweichung Stopp.
3. Erst nach bestätigter Isolation und R2: Recorder beenden, den **gleichen** Port exklusiv mit `screen /dev/cu.usbmodem… 115200` (oder serieller Terminal-App) öffnen. In der Diagnosekonsole genau eine Zeile eingeben und Enter drücken: `LOAD FABRIC ID: RAM, ISOLATION AND R2 VERIFIED`. Das ist keine Shell. Kein Echo. Nicht wiederholt senden: die Initialisierung akzeptiert höchstens einen Versuch pro Boot; hat der Host die Eingabe verloren, ist das Ausbleiben eines Ergebnisblocks ein Stoppsignal. Terminal schließen und Recorder wieder starten; Init wiederholt den Ergebnisblock nach dem einmaligen Versuch. Die Ausgabe geht zusätzlich an `/dev/console`.
4. Erwarteter Ablauf: `event=start` (Build, SS1/Mode/Takte), beide SHA-256 samt Bytes, `cdone=0 stage=reset`, `cdone=1 stage=uploaded ... offset=0`, dann die fünf gelesenen Werte und `result=pass cdone=1 offline=yes audio_qualified=no`. Registerwerte: `0x1800=0x57494e47`, `0x1804=0x00020000`, `0x1808` = Build-ID aus Manifest, `0x180c=0`, `0x1810=1`. Native x1-Bytes beginnen bei Byte 0, einschließlich **256-Byte-Header** vor `168a2236`. Keine 260-Byte-Skips. Kein Produkt-Receipt; Ergebnislog `/run/wing-fabric-id.log`, Mac-Logpfad gibt der Recorder aus.
5. Bei `result=fail`, Timeout (für den Upload und Replay bis 30 s ab Eingabe), USB-Abbruch oder unerwarteten Signalen: Stopp, nicht neu senden. Loader setzt SS1 auch auf dem Fehlerpfad wieder offline; der Bench-Treiber setzt den Zustand außerdem beim Schließen zurück. Kein automatisches CRESET oder Reload. `offline=untouched` heißt, dass der Loader das Gerät nicht geöffnet hat; `unknown` heißt, der Offline-Wechsel konnte nicht bestätigt werden. Auch bei PASS bleibt die Diagnose-Fabric volatil konfiguriert. Externe Isolation beibehalten, Logs sichern und im bestätigten flüchtigen Aufbau kontrolliert ausschalten; nicht blind warm neustarten. Produkt-/Audiotest erst separat nach eigener Freigabe.

SS1 hat kein CSR-Schreib-, Burst- oder Raw-IOCTL. Der privilegierte SS0-spidev-Knoten ist nur der interne Konfigurationstransport des gebundenen Loaders; das Paket gibt weder eine Shell noch direkten Zugriff auf ihn frei. `CAP_SYS_RAWIO`, OFFLINE-Gate, geprüfte WING-Identität und getrenntes Benchprofil bleiben verpflichtend.

## Reproduktion (ohne Board)

Dieses Profil direkt aus diesem Checkout bauen; kein zusätzliches `source.patch` anwenden. Es übernimmt WING-Pinmap, Efinity-Projektgenerator, Migen-SPIBone und den kernelbasierten Bootstrap vom integrierten Design. Der historische Ausgangscommit `925cc382a2c65affa7866dc313d598a187b6d0d7` bleibt Teil der Identitätsberechnung; die tatsächlichen Gateware-Eingaben werden separat gehasht. Das Profil bindet **keinen** AES50-/Audio-Core und keine Submodule ein. Mit gepinntem LiteX/Migen (`litex_soc/requirements.txt`):

```sh
python platforms/wing_trion/fabric_id/generate_id.py build/fabric-id
# Auf dem isolierten Linux-Buildrechner, im generierten Verzeichnis:
source /opt/efinity/2026.1/bin/setup.sh
efx_run wing-fpga.xml --flow compile
test -s outflow/wing-fpga.bit && test -s outflow/wing-fpga.hex.bin
# Die Outputs in build/fabric-id/outflow zurückkopieren, dann binden:
python platforms/wing_trion/fabric_id/generate_id.py --bind build/fabric-id
```

Die OpenWING-Diagnosequellen und die Buildumgebung für den folgenden Linux-Bau sind zusätzliche Eingaben und nicht Teil dieses Repos. Ohne passende Eingaben sind nur Gateware und ihre Simulation reproduzierbar.

Linux-Bau: im gepinnten OpenWING-Buildcontainer `wing-usb-console-builder:trixie` (Docker-CLI, `--network none`) den eigenen Worktree schreibgeschützt als `/oa`, `openwing-inputs` schreibgeschützt als `/openwing`, die archivgeprüften Linux-/BusyBox-Quellen als `/archives`, ein frisches case-sensitives Volume als `/work` mounten. `bash /oa/platforms/wing_trion/fabric_id/linux-build.sh kernel` ausführen. Mit demselben Volume, zusätzlichem generiertem `build/fabric-id` als `/gateware:ro` und einem leeren Ausgabeverzeichnis als `/out` `…/linux-build.sh package` ausführen. Efinity kann Zeitstempel und Pfad in den exportierten Bytes variieren; darum neu binden und Loader neu bauen, nie Hashes der alten Ausgabe wiederverwenden.

`verify_fit.py <linux/…itb> <gateware> <openwing-inputs/tools/wing-t55-diag/wing-t55-diag>` braucht `dumpimage`/`fdtget`. `tb_identity.v` mit `iverilog -g2012 -s tb_identity` gemeinsam mit `wing_fpga.v` simulieren (`vvp … +build=<acht Hex-Zeichen>`). `bash platforms/wing_trion/fabric_id/test_loader.sh build/fabric-id` auf einem Linux-Buildrechner als root, mit gcc, Python und einem Kernel mit AF_ALG/SHA-256. Der Mock fängt Zugriff auf Geräte vollständig ab und leitet Dateien in ein eigenes `/dev/shm`-Verzeichnis um; keine Ausführung am Board. Logdateien enthalten die Offline-Ergebnisse. Diese Prüfungen bestätigen keine Bootpegel, Boardrevision, Live-Transporttimings oder Startkette.
