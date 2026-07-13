# %% [markdown]
# # europa — notebook mode
# Cells run on a Jupyter kernel; output renders **inline**.
# (`,c` runs a cell, `,n` runs and jumps to the next.)

# %%
import time
import warnings

import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

rng = np.random.default_rng(42)
print(f"numpy {np.__version__} · pandas {pd.__version__}")

# %% a pandas table renders straight into the buffer
df = pd.DataFrame({
    "city": ["Tokyo", "Nairobi", "Oslo", "Lima", "Sydney"],
    "temp_c": rng.normal(18, 8, 5).round(1),
    "humidity": rng.integers(35, 90, 5),
    "rainy": rng.random(5) > 0.5,
})
df

# %% aggregates too
df.describe().round(2)

# %% matplotlib figures draw inline (kitty graphics — works over ssh/tmux)
x = np.linspace(0, 4 * np.pi, 400)
fig, ax = plt.subplots(figsize=(7, 3.2))
for k in range(1, 6):
    ax.plot(x, np.sin(k * x) / k, lw=2, label=f"sin({k}x)/{k}")
ax.set_title("harmonics")
ax.legend(ncols=5, fontsize=8, frameon=False)
plt.tight_layout()
plt.show()

# %% colormaps, colorbars — anything matplotlib can render
pts = rng.normal(size=(900, 2))
r = np.hypot(pts[:, 0], pts[:, 1])
fig, ax = plt.subplots(figsize=(5.2, 3.8))
sc = ax.scatter(*pts.T, c=r, s=12, cmap="viridis", alpha=0.85)
fig.colorbar(sc, ax=ax, label="radius")
ax.set_title("gaussian cloud")
plt.tight_layout()
plt.show()

# %% streaming output paints live — \r progress bars collapse cleanly
for i in range(1, 21):
    bar = "█" * i + "·" * (20 - i)
    print(f"\rtraining [{bar}] {i * 5:3d}%", end="")
    time.sleep(0.12)
print("\nloss=0.042  ✓ converged")

# %% stderr gets its own color
warnings.warn("careful — this run used the demo settings")
print("stdout and stderr, side by side")

# %% [markdown]
# **More:** `,o` opens a cell's full output (figures enlarged) in a popup ·
# `,z` folds all code, leaving markdown + outputs — a readable report ·
# `,i` interrupts a runaway cell.
