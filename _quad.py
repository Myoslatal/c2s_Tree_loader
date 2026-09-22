import re
P = "_mod_tools/CustomEventPack/CustomEventPackPlugin.cs"
t = open(P, encoding="utf-8").read()

# --- helpers, inserted just before ApplyEventBackground ---
anchor = "\tinternal static void ApplyEventBackground(Pack pack)"
assert t.count(anchor) == 1
helpers = '''	/// <summary>A 1x1 quad mesh facing -Z (i.e. back towards the camera it is parented to).</summary>
	internal static Mesh MakeQuadMesh()
	{
		Mesh mesh = new Mesh();
		mesh.name = "cepack_quad";
		mesh.vertices = new Vector3[4]
		{
			new Vector3(-0.5f, -0.5f, 0f),
			new Vector3(0.5f, -0.5f, 0f),
			new Vector3(0.5f, 0.5f, 0f),
			new Vector3(-0.5f, 0.5f, 0f)
		};
		mesh.uv = new Vector2[4]
		{
			new Vector2(0f, 0f),
			new Vector2(1f, 0f),
			new Vector2(1f, 1f),
			new Vector2(0f, 1f)
		};
		mesh.normals = new Vector3[4] { Vector3.back, Vector3.back, Vector3.back, Vector3.back };
		mesh.triangles = new int[6] { 0, 2, 1, 0, 3, 2 };
		mesh.RecalculateBounds();
		return mesh;
	}

	/// <summary>Unlit material. Uses a texture when given one, a flat colour otherwise.</summary>
	internal static Material MakeUnlit(Texture2D tex, Color col)
	{
		Shader shader = null;
		string[] wanted = (tex != null)
			? new string[3] { "Unlit/Texture", "Sprites/Default", "UI/Default" }
			: new string[3] { "Unlit/Color", "Sprites/Default", "UI/Default" };
		foreach (string sn in wanted)
		{
			shader = Shader.Find(sn);
			if (shader != null)
			{
				break;
			}
		}
		if (shader == null)
		{
			shader = Shader.Find("Unlit/Texture");
		}
		Material material = new Material(shader);
		if (tex != null)
		{
			material.mainTexture = tex;
		}
		material.color = col;
		return material;
	}

	/// <summary>
	/// A full-view quad parented to the camera at distance z. Parenting makes the size
	/// exact for ANY camera: at distance d a perspective camera sees
	/// 2*d*tan(fov/2) vertically, times the aspect horizontally, so the quad covers the
	/// viewport regardless of which camera renders and what its fov happens to be.
	/// </summary>
	internal static GameObject MakeViewQuad(Camera cam, string name, float z, float w, float h, Material mat)
	{
		GameObject go = new GameObject(name);
		go.layer = cam.gameObject.layer;
		MeshFilter mf = go.AddComponent<MeshFilter>();
		mf.sharedMesh = MakeQuadMesh();
		MeshRenderer mr = go.AddComponent<MeshRenderer>();
		mr.sharedMaterial = mat;
		mr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
		mr.receiveShadows = false;
		// +Z is where the camera looks, so the quad must face back towards it
		go.transform.SetParent(cam.transform, false);
		go.transform.localPosition = new Vector3(0f, 0f, z);
		go.transform.localRotation = Quaternion.Euler(0f, 180f, 0f);
		go.transform.localScale = new Vector3(w, h, 1f);
		return go;
	}

'''
t = t.replace(anchor, helpers + anchor)

# --- create the layers right after the texture replacement ---
old = '\t\t\t\tLog.Info("BG FIX: " + num + " backdrop texture(s) replaced");\n\t\t\t\t}'
print("anchor2 count:", t.count(old))
if t.count(old) == 0:
    old = '\t\t\t\t\tLog.Info("BG FIX: " + num + " backdrop texture(s) replaced");\n\t\t\t\t}'
    print("retry count:", t.count(old))
new = old + '''
				// ---- OUR OWN LAYER, BETWEEN THE NODES AND THE BACKDROP --------------------
				// This is what finally replaced painting/hunting the game's own backdrop.
				// The probe measured the tree nodes at 250-259 units from the camera and the
				// original backdrop at 370, so a quad at 320 is guaranteed to draw BEHIND
				// every node and IN FRONT of whatever paints the original background - no
				// need to know what that object is. A flat black quad sits 1 unit further
				// back so any transparency in the art still hides the original.
				if (text != null)
				{
					try
					{
						Camera camQ = Camera.main;
						if (camQ != null)
						{
							float d = 320f;
							float qh = 2f * d * Mathf.Tan(camQ.fieldOfView * 0.5f * ((float)Math.PI / 180f)) * 1.2f;
							float qw = qh * (float)Screen.width / (float)Screen.height;
							Texture2D art = new Texture2D(2, 2, TextureFormat.RGBA32, false);
							art.LoadImage(File.ReadAllBytes(text));
							art.wrapMode = TextureWrapMode.Clamp;
							MakeViewQuad(camQ, "cepack_bg_black", d + 1f, qw, qh, MakeUnlit(null, Color.black));
							MakeViewQuad(camQ, "cepack_bg_image", d, qw, qh, MakeUnlit(art, Color.white));
							Log.Info("BG QUAD: cam='" + camQ.name + "' fov=" + camQ.fieldOfView.ToString("F1") +
							         " d=" + d + " size=" + qw.ToString("F0") + "x" + qh.ToString("F0") +
							         " screen=" + Screen.width + "x" + Screen.height);
						}
						else
						{
							Log.Warn("BG QUAD: Camera.main is null");
						}
					}
					catch (Exception eQ)
					{
						Log.Error("BG QUAD", eQ);
					}
				}'''
t = t.replace(old, new, 1)
open(P, "w", encoding="utf-8").write(t)
print("inserted")
