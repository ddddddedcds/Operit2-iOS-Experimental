#!/usr/bin/env python3
"""CLI entry for the AutoGLM + ios-mcp iOS agent prototype.

Usage:
  export AUTOGLM_API_KEY="your-key"
  python3 run.py "打开抖音搜索猫咪视频"
  # 也支持显式写法: python3 run.py --task "打开抖音搜索猫咪视频"

Options:
  --task       natural-language task (positional 或 --task 均可)
  --mcp-url    ios-mcp endpoint (default http://192.168.1.21:8090/mcp)
  --base-url   AutoGLM API base (default https://open.bigmodel.cn/api/paas/v4)
  --model      model name (default autoglm-phone)
  --max-steps  safety cap (default 30)
  --api-key    override AUTOGLM_API_KEY env
"""

import argparse
import os
import sys

from agent import AutoGlmIosAgent


def main():
    p = argparse.ArgumentParser()
    p.add_argument("task_pos", nargs="?", help="natural-language task (positional)")
    p.add_argument("--task", dest="task_opt", help="natural-language task (explicit)")
    p.add_argument("--mcp-url", default="http://192.168.1.21:8090/mcp")
    p.add_argument("--base-url", default="https://open.bigmodel.cn/api/paas/v4")
    p.add_argument("--model", default="autoglm-phone")
    p.add_argument("--max-steps", type=int, default=30)
    p.add_argument("--api-key", default=os.environ.get("AUTOGLM_API_KEY", ""))
    args = p.parse_args()

    task = args.task_pos or args.task_opt
    if not task:
        print("ERROR: 请提供一个任务，例如: python3 run.py \"打开抖音搜索猫咪视频\"")
        sys.exit(2)

    if not args.api_key:
        print("ERROR: set AUTOGLM_API_KEY (or pass --api-key).")
        sys.exit(2)

    agent = AutoGlmIosAgent(
        api_key=args.api_key,
        mcp_url=args.mcp_url,
        base_url=args.base_url,
        model=args.model,
        max_steps=args.max_steps,
    )
    result = agent.run(task)
    print(f"\n=== RESULT ===\n{result}")


if __name__ == "__main__":
    main()
