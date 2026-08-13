# InfluxDB 3 Install Script

This repository exists to maintain `install_influxdb.sh`, the installation script for
[InfluxDB 3][influxdb] Core and Enterprise. Nothing else is developed here.

The script is published at <https://www.influxdata.com/d/install_influxdb3.sh>, which serves the copy maintained in this
repository. The [InfluxData downloads page][downloads] links to it.

## Usage

Install Core:

```sh
curl -O https://www.influxdata.com/d/install_influxdb3.sh && sh install_influxdb3.sh
```

Install Enterprise:

```sh
curl -O https://www.influxdata.com/d/install_influxdb3.sh && sh install_influxdb3.sh enterprise
```

Pass `--version VERSION` to install a specific release instead of the default.

The script is intended for quick installation and evaluation.

[influxdb]: https://github.com/influxdata/influxdb
[downloads]: https://www.influxdata.com/downloads/
