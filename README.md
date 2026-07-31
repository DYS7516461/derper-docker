# DERPer Docker

用 GitHub Actions 自编译 DERPer Docker 镜像，并推送到 GHCR、阿里云 ACR 和 Docker Hub。服务器只需要 `docker compose pull` 和 `docker compose up -d`，不需要安装 Go、Docker Buildx 或在本机编译。

DERPer 来自 Tailscale 官方 Go 包：`tailscale.com/cmd/derper`。

## 仓库结构

```text
derper-docker/
├── Dockerfile
├── docker-compose.yml
├── docker-compose.host.yml
├── docker-compose.bridge.yml
├── docker-compose.verify-clients.yml
├── .env.example
├── .github/workflows/build.yml
├── README.md
└── LICENSE
```

## 镜像构建

`Dockerfile` 使用多阶段构建：

1. `golang:1.25-bookworm` 编译 `tailscale.com/cmd/derper@${TAILSCALE_VERSION}`。
2. `debian:bookworm-slim` 作为运行镜像，只安装 `ca-certificates` 并复制 `derper` 二进制。

默认版本是：

```dockerfile
ARG TAILSCALE_VERSION=v1.86.2
```

GitHub Actions 会在构建时通过 `--build-arg TAILSCALE_VERSION=...` 覆盖它。

## GitHub Actions 发布

工作流文件：`.github/workflows/build.yml`

支持两种触发方式：

- 推送 Git Tag，例如 `v1.86.2`。
- 在 GitHub Actions 页面手动运行，并输入 `tailscale_version`。

发布 tag 时会构建：

```text
linux/amd64
linux/arm64
```

并推送：

```text
ghcr.io/<owner>/<repo>:v1.86.2
ghcr.io/<owner>/<repo>:latest
registry.cn-hangzhou.aliyuncs.com/<namespace>/derper:v1.86.2
registry.cn-hangzhou.aliyuncs.com/<namespace>/derper:latest
docker.io/<dockerhub-namespace>/<dockerhub-image>:v1.86.2
docker.io/<dockerhub-namespace>/<dockerhub-image>:latest
```

手动运行时默认只推送输入的版本 tag；如果勾选 `push_latest`，也会推送 `latest`。

### GitHub Secrets

GHCR 使用 `GHCR_TOKEN`。请在 GitHub Repository Settings -> Secrets and variables -> Actions 里配置：

```text
GHCR_TOKEN=your-github-token
```

`GHCR_TOKEN` 可以使用 GitHub Personal Access Token，至少需要 `write:packages` 权限。如果仓库是私有仓库，通常还需要 `repo` 权限。

不要手动创建名为 `GITHUB_TOKEN` 的 Secret。`GITHUB_TOKEN` 是 GitHub Actions 的内置 token，GitHub 不允许用户创建以 `GITHUB_` 开头的 Secret。

如果要推送 Docker Hub，需要配置 Repository Variables：

```text
DOCKERHUB_NAMESPACE=your-dockerhub-namespace
DOCKERHUB_IMAGE=derper
```

`DOCKERHUB_IMAGE` 可选，不配置时默认使用 `derper`。

还需要配置 Repository Secrets：

```text
DOCKERHUB_USERNAME=your-dockerhub-username
DOCKERHUB_TOKEN=your-dockerhub-token
```

建议使用 Docker Hub Access Token，不要直接使用账号密码。

如果要推送阿里云 ACR，需要在 GitHub Repository Settings -> Secrets and variables -> Actions 里配置：

```text
ALIYUN_REGISTRY=registry.cn-hangzhou.aliyuncs.com
ALIYUN_NAMESPACE=your-namespace
ALIYUN_USERNAME=your-acr-username
ALIYUN_PASSWORD=your-acr-password
```

建议使用阿里云 ACR 的访问凭证，不要直接使用主账号密码。

如果没有配置这些 ACR secrets，workflow 会继续推送 GHCR 和已启用的其他仓库，只跳过 ACR。

如果没有完整配置 Docker Hub 的 namespace、username 和 token，workflow 会跳过 Docker Hub，不影响 GHCR / ACR。

### 发版流程

```bash
git tag v1.86.2
git push origin v1.86.2
```

之后 GitHub Actions 会自动构建并推送镜像。

## 服务器部署

复制环境变量模板：

```bash
cp .env.example .env
```

编辑 `.env`：

```dotenv
DERP_HOSTNAME=derp.example.com
DERPER_IMAGE=registry.cn-hangzhou.aliyuncs.com/your-namespace/derper:latest
TZ=Asia/Shanghai
```

也可以使用 Docker Hub 镜像：

```dotenv
DERPER_IMAGE=your-dockerhub-namespace/derper:latest
```

默认使用 host 网络：

```bash
docker compose up -d
```

更新镜像：

```bash
docker compose pull
docker compose up -d
```

### Host 网络模式

默认 `docker-compose.yml` 和 `docker-compose.host.yml` 都使用 host 网络。适合 Linux 服务器，端口映射最少，STUN UDP 行为也更直接。

```bash
docker compose -f docker-compose.host.yml up -d
```

### Bridge 网络模式

如果你不能使用 host 网络，可以使用 bridge 模式：

```bash
docker compose -f docker-compose.bridge.yml up -d
```

默认映射：

```text
80/tcp    -> Let's Encrypt HTTP 验证
443/tcp   -> DERP HTTPS
3478/udp  -> STUN
```

Let's Encrypt 证书会保存在 Docker volume `derper-certs` 中，容器重建后不会丢失。

### 服务器 80 和 443 已被 nginx 占用

DERP 不建议放在普通 HTTP 反向代理后面，例如 nginx `location` + `proxy_pass`。DERP 客户端会先建立 TLS 连接，然后在连接内部升级到 DERP 自己的双向协议；普通 HTTP 反代很容易破坏这个连接。

遇到 nginx 已经占用 TCP `80` 和 `443` 时，建议按下面优先级选择。

#### 方案 A：DERPer 使用非标准 HTTPS 端口

这是最简单、最稳的共存方式：nginx 继续使用 `80/443`，DERPer 使用例如 `8443/tcp`，STUN 仍使用 `3478/udp`。

`.env` 示例：

```dotenv
DERP_HOSTNAME=derp.example.com
DERP_CERT_MODE=manual
DERP_HTTP_PORT=-1
DERP_HTTPS_PORT=8443
DERP_STUN_PORT=3478
```

`DERP_CERT_MODE=manual` 表示 DERPer 不再自己申请 Let's Encrypt 证书。你需要用 nginx、certbot、acme.sh 或 DNS-01 先为 `DERP_HOSTNAME` 申请证书，然后让容器能读到这两个文件：

```text
/var/lib/derper/certs/derp.example.com.crt
/var/lib/derper/certs/derp.example.com.key
```

如果证书在宿主机 `/etc/letsencrypt/live/derp.example.com/`，可以增加一个本地 override 文件 `docker-compose.manual-cert.yml`：

```yaml
services:
  derper:
    volumes:
      - /etc/letsencrypt/live/derp.example.com/fullchain.pem:/var/lib/derper/certs/derp.example.com.crt:ro
      - /etc/letsencrypt/live/derp.example.com/privkey.pem:/var/lib/derper/certs/derp.example.com.key:ro
```

然后启动：

```bash
docker compose -f docker-compose.host.yml -f docker-compose.manual-cert.yml up -d
```

此时 tailnet policy file 里的 DERP 节点也要写 `DERPPort: 8443`：

```json
{
  "Name": "901a",
  "RegionID": 901,
  "HostName": "derp.example.com",
  "DERPPort": 8443,
  "STUNPort": 3478
}
```

防火墙需要放行 TCP `8443` 和 UDP `3478`。TCP `80/443` 继续留给 nginx。

#### 方案 B：nginx stream 按 SNI 做 TCP 透传

如果你必须让 DERP 也使用公网 `443/tcp`，可以把 nginx 的 `443` 改成 stream 四层入口，根据 SNI 把 `derp.example.com` 透传给 DERPer，把其他域名透传给原来的 HTTPS 站点。

思路示例：

```nginx
stream {
    map $ssl_preread_server_name $backend {
        derp.example.com derper_backend;
        default web_backend;
    }

    upstream derper_backend {
        server 127.0.0.1:8443;
    }

    upstream web_backend {
        server 127.0.0.1:4443;
    }

    server {
        listen 443;
        proxy_pass $backend;
        ssl_preread on;
    }
}
```

这种方式不是 HTTP 反代，而是 TCP 透传，TLS 仍由 DERPer 自己处理。原有 nginx HTTPS 站点需要从公网 `443` 改到内部端口，例如 `127.0.0.1:4443`。如果你不熟悉 nginx `stream`，优先使用方案 A 或单独服务器/IP。

#### 方案 C：单独服务器或单独公网 IP

如果可以给 DERPer 一台单独服务器，或者给同一台服务器增加一个单独公网 IP，让 DERPer 独占该 IP 的 `80/443/3478` 是最省心的方案。这样可以继续使用默认 `DERP_CERT_MODE=letsencrypt`，也不用改 nginx 的现有站点。

## DNS 和防火墙

请确保：

- `DERP_HOSTNAME` 的 A/AAAA 记录指向服务器公网 IP。
- TCP `80` 对公网开放，用于 Let's Encrypt HTTP 验证。
- TCP `443` 对公网开放，用于 DERP。
- UDP `3478` 对公网开放，用于 STUN。

如果服务器前面有安全组、防火墙或云厂商 ACL，需要同时放行这些端口。

## Tailscale 配置示例

在 tailnet policy file 中加入自定义 `derpMap`，示例：

```json
{
  "derpMap": {
    "Regions": {
      "901": {
        "RegionID": 901,
        "RegionCode": "custom-cn",
        "RegionName": "Custom China DERP",
        "Nodes": [
          {
            "Name": "901a",
            "RegionID": 901,
            "HostName": "derp.example.com",
            "DERPPort": 443,
            "STUNPort": 3478
          }
        ]
      }
    }
  }
}
```

把 `derp.example.com` 换成你的 `DERP_HOSTNAME`。

## 启用 DERPer 客户端认证

默认 `DERP_VERIFY_CLIENTS=false` 时，只要别人知道你的 `derpMap`，理论上就可以尝试连接这个 DERPer。想限制为指定用户或指定 tailnet 成员，需要启用 DERPer 的客户端验证：

```dotenv
DERP_VERIFY_CLIENTS=true
```

客户端验证依赖宿主机上的 `tailscaled`。它不是 HTTP Basic Auth，也不是用户名密码认证；DERPer 会通过本机 Tailscale LocalAPI 校验连接过来的 Tailscale 节点是否属于本机 `tailscaled` 可见的 tailnet。

启用步骤：

1. 在 DERPer 宿主机安装并登录 Tailscale：

```bash
tailscale up
```

2. 建议把这台 DERPer 主机打上专用 tag，例如 `tag:derper`，方便用 ACL 控制哪些用户或设备能“看见”它。

3. 使用带 socket 挂载的 compose override 启动：

```bash
docker compose -f docker-compose.host.yml -f docker-compose.verify-clients.yml up -d
```

如果使用 bridge 网络，也可以组合：

```bash
docker compose -f docker-compose.bridge.yml -f docker-compose.verify-clients.yml up -d
```

4. 在 Tailscale policy file 中只允许指定用户访问这台 DERPer 主机。Tailscale 现在推荐新配置使用 `grants`，示例：

```json
{
  "groups": {
    "group:derp-users": [
      "alice@example.com",
      "bob@example.com"
    ]
  },
  "tagOwners": {
    "tag:derper": ["autogroup:admin"]
  },
  "grants": [
    {
      "src": ["group:derp-users"],
      "dst": ["tag:derper"],
      "ip": ["*"]
    }
  ]
}
```

如果你的 policy file 里已有类似允许所有成员访问所有设备的宽泛 `grants` 或旧版 `acls` 规则，所有成员可能仍然能被 DERPer 验证通过。要实现“指定用户才可以使用”，需要避免这些宽泛规则覆盖 `tag:derper`。

## 共享给朋友使用

共享自建 DERPer 时，先区分朋友是否在你的 tailnet 里。

### 朋友加入你的 tailnet

这是最适合“指定用户”的方式：

1. 邀请朋友加入你的 tailnet，或让朋友的设备以你允许的账号登录。
2. 在 policy file 中把朋友账号加入 `group:derp-users`。
3. 保持 `DERP_VERIFY_CLIENTS=true`。
4. 在你的 tailnet policy file 中发布上面的 `derpMap`。

这样只有 policy file 允许的用户或设备可以通过验证并使用这个 DERPer。

### 朋友使用自己的 tailnet

如果朋友使用的是他自己的 tailnet，他也需要在自己的 tailnet policy file 中添加同样的 `derpMap`。但是需要注意：`DERP_VERIFY_CLIENTS=true` 只能验证 DERPer 宿主机本机 `tailscaled` 所在 tailnet 中可见的节点，不能直接验证另一个独立 tailnet 的成员。

因此跨 tailnet 共享通常有三个选择：

- 不开启客户端验证，只把 `derpMap` 给朋友；这最简单，但不是“指定用户”。
- 为朋友单独部署一套 DERPer，并让那台 DERPer 宿主机登录朋友自己的 tailnet。
- 让朋友加入你的 tailnet，然后按上一节用 ACL 指定用户。

如果目标是“只给几个朋友用，并且不公开给陌生人”，推荐让朋友加入你的 tailnet，再开启 `DERP_VERIFY_CLIENTS=true` 和 policy file 分组。

## 本地测试构建

如果本机安装了 Docker，可以手动构建：

```bash
docker build --build-arg TAILSCALE_VERSION=v1.86.2 -t derper:local .
```

如果本机安装了 Docker Compose，可以检查配置：

```bash
docker compose --env-file .env.example config
docker compose -f docker-compose.bridge.yml --env-file .env.example config
```

## 常见注意事项

- `latest` 适合个人服务器自动跟随最新发布；生产环境也可以固定到 `v1.86.2` 这类版本 tag。
- 首次启动时 DERPer 会根据 `--certmode=letsencrypt` 自动申请证书，前提是 DNS 和 TCP `80` 已经正确开放。
- DERP 协议会在 TLS 内部切换到自定义双向协议，不适合放在普通 HTTP 反向代理后面；推荐让 DERPer 直接监听公网 `443/tcp`。
- 国内服务器建议部署时使用阿里云 ACR 镜像地址，拉取会更稳定。
- 公共开源用户可以直接使用 GHCR 或 Docker Hub 镜像地址。
