import Foundation
#if canImport(PlanOpsisCore)
@testable import PlanOpsisCore
#else
@testable import PlanOpsisMobile
#endif

/// Real RoomPlan captures retained by PlanOpsis (`roomPlanCapture` evidence), used as regression and
/// reconstruction-benchmark cases. Geometry only; no images or personal data.
enum RealCaptureFixtures {
    /// v12.1 field capture, 2026-10: one irregular room, 20 wall surfaces (one non-rectangular),
    /// one door, one window, one opening. Floor at about -1.617 m in capture space.
    static func apartment1() throws -> StructureCaptureSnapshot {
        try CaptureEvidence.decode(Data(apartment1JSON.utf8))
    }

    static let apartment1JSON = #"""
{
 "rooms": [
  {
   "sourceRoomPlanID": "FA80C002-74CA-4417-94CE-9E0D88650547",
   "surfaces": [
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 7.512612342834473,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "2FD2A114-D882-4212-B45E-6DA844EA5A80",
     "transform": {
      "values": [
       -0.8207153081893921,
       0,
       -0.5713375210762024,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       0.5713374614715576,
       0,
       -0.8207152485847473,
       0,
       0.9810094237327576,
       -0.31183913350105286,
       2.858175754547119,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 3.5229709148406982,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "8800C869-20FF-4585-A1E4-F0BA3917B8BB",
     "transform": {
      "values": [
       0.8207151889801025,
       0,
       0.5713375210762024,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.5713375210762024,
       0,
       0.8207152485847473,
       0,
       1.9150527715682983,
       -0.31183913350105286,
       -0.7021879553794861,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 3.0064749717712402,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "C4DED968-AB83-4AA1-B644-6A162EFC1952",
     "transform": {
      "values": [
       0.5713375806808472,
       0,
       -0.8207152485847473,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       0.8207151889801025,
       0,
       0.5713375210762024,
       0,
       -1.2429921627044678,
       -0.31183913350105286,
       -0.5216729640960693,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.44922351837158203,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "759A161F-A44B-4309-9625-6B364ECB0452",
     "transform": {
      "values": [
       0.5713375210762024,
       0,
       -0.8207151889801025,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       0.8207152485847473,
       0,
       0.5713375210762024,
       0,
       0.3410457372665405,
       -0.31183913350105286,
       -1.5242483615875244,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.6072101593017578,
      "y": 2.7089452743530273,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "72FFA6A3-A7D9-4C84-A049-E2B61A349536",
     "transform": {
      "values": [
       -0.5713374614715576,
       0,
       0.8207153081893921,
       0,
       0,
       1,
       0,
       0,
       -0.8207153081893921,
       0,
       -0.5713374614715576,
       0,
       7.333311557769775,
       -0.262366384267807,
       4.983154773712158,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.7272350788116455,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "FB1B4F0E-7722-4F89-80DB-6E7CEA312D57",
     "transform": {
      "values": [
       0.8207151889801025,
       0,
       0.5713375210762024,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.5713375210762024,
       0,
       0.8207152485847473,
       0,
       -0.08570986986160278,
       -0.31183913350105286,
       -1.547654390335083,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 2.697197675704956,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "E90F2BDC-8D4F-45F3-951A-3D24604D9DBD",
     "transform": {
      "values": [
       -0.5713375806808472,
       0,
       0.8207151889801025,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.8207151293754578,
       0,
       -0.5713375210762024,
       0,
       4.834372043609619,
       -0.31183913350105286,
       3.8974790573120117,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.1458049714565277,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "B0686BA3-F5BD-4538-84F7-A80D0B05355A",
     "transform": {
      "values": [
       -0.5713363289833069,
       0,
       0.8207159638404846,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.8207160234451294,
       0,
       -0.5713363289833069,
       0,
       3.3190786838531494,
       -0.31183913350105286,
       0.36404702067375183,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.0194531679153442,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "7C59142E-7C20-459A-A5A7-9CAC7D34595C",
     "transform": {
      "values": [
       -0.8207150101661682,
       0,
       -0.5713375806808472,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       0.5713375806808472,
       0,
       -0.820715069770813,
       0,
       4.482207298278809,
       -0.31183913350105286,
       5.295520782470703,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.4236638844013214,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "7FC1FB45-B3E5-4094-81B0-2CA341F421F1",
     "transform": {
      "values": [
       0.8207152485847473,
       0,
       0.5713373422622681,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.5713373422622681,
       0,
       0.8207153081893921,
       0,
       3.4512808322906494,
       -0.31183913350105286,
       0.5449066758155823,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.16208438575267792,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "38E8142F-CF55-49E2-B191-DC08FA060509",
     "transform": {
      "values": [
       0.5713380575180054,
       0,
       -0.8207148313522339,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       0.8207147717475891,
       0,
       0.5713379979133606,
       0,
       3.6714370250701904,
       -0.31183913350105286,
       0.5994216799736023,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.8836004137992859,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "009E3882-E2B5-439B-88A8-1DE8CF4E076B",
     "transform": {
      "values": [
       -0.4537102282047272,
       0,
       0.8911491632461548,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.8911492228507996,
       0,
       -0.45371025800704956,
       0,
       6.600780963897705,
       -0.31183913350105286,
       2.9608023166656494,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.5873486995697021,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "75159963-0B9A-4573-9A52-C9A81F64C088",
     "transform": {
      "values": [
       0.8207152485847473,
       0,
       0.5713376402854919,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.5713375806808472,
       0,
       0.8207151889801025,
       0,
       7.452610015869141,
       -0.31183913350105286,
       3.0205483436584473,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 3.6940245628356934,
      "y": 2.609999895095825,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "300DB568-F23C-47E6-8E1F-C01A3A65B1EA",
     "transform": {
      "values": [
       0.8347240686416626,
       0,
       0.5506685972213745,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.5506685376167297,
       0,
       0.8347240090370178,
       0,
       5.259484767913818,
       -0.31183913350105286,
       1.5500006675720215,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.8752956390380859,
      "y": 2.7089452743530273,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 4
     },
     "sourceRoomPlanID": "51A433B2-F82B-4831-8111-6394893BB4CD",
     "transform": {
      "values": [
       -0.5713372230529785,
       0,
       0.8207154273986816,
       0,
       0,
       1,
       0,
       0,
       -0.8207154273986816,
       0,
       -0.5713372230529785,
       0,
       7.853946685791016,
       -0.262366384267807,
       3.833188533782959,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.22972522675991058,
      "y": 2.7089452743530273,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "DDB0D15F-954B-4015-BEAD-1791E41F188C",
     "transform": {
      "values": [
       0.8207152485847473,
       0,
       0.5713374614715576,
       0,
       0,
       1,
       0,
       0,
       -0.5713374614715576,
       0,
       0.8207152485847473,
       0,
       7.698171615600586,
       -0.262366384267807,
       4.257997989654541,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.4664901494979858,
      "y": 2.7089452743530273,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "E06F14E7-E84B-467C-BEBF-16645C154B74",
     "transform": {
      "values": [
       0.8207152485847473,
       0,
       0.5713374614715576,
       0,
       0,
       1,
       0,
       0,
       -0.5713374614715576,
       0,
       0.8207152485847473,
       0,
       7.002116680145264,
       -0.262366384267807,
       3.773442506790161,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.0841728448867798,
      "y": 2.325000047683716,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "59DDC247-C910-4DF5-AF3F-59A430003198",
     "transform": {
      "values": [
       -0.6254199147224426,
       0,
       0.7802883982658386,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.7802884578704834,
       0,
       -0.6254199147224426,
       0,
       5.239579677581787,
       -0.45433908700942993,
       5.16376256942749,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 0.8256301283836365,
      "y": 2.325000047683716,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "91A390EE-AC87-43B0-A821-FD8CA30CEE16",
     "transform": {
      "values": [
       -0.5713374614715576,
       0,
       0.8207151889801025,
       0,
       0,
       0.9999999403953552,
       0,
       0,
       -0.8207152485847473,
       0,
       -0.5713374614715576,
       0,
       5.814467430114746,
       -0.45433908700942993,
       4.401975631713867,
       1
      ]
     }
    },
    {
     "category": "wall",
     "confidence": "high",
     "dimensions": {
      "x": 1.5785880088806152,
      "y": 2.7089452743530273,
      "z": 0
     },
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "63C3D885-B5DA-48FB-8992-C9698DE294D1",
     "transform": {
      "values": [
       -0.8207152485847473,
       0,
       -0.5713376402854919,
       0,
       0,
       1,
       0,
       0,
       0.5713375806808472,
       0,
       -0.8207151293754578,
       0,
       6.226396083831787,
       -0.262366384267807,
       5.191731929779053,
       1
      ]
     }
    },
    {
     "category": "door",
     "confidence": "medium",
     "dimensions": {
      "x": 0.7264872193336487,
      "y": 2.302706718444824,
      "z": 0
     },
     "parentIdentifier": "009E3882-E2B5-439B-88A8-1DE8CF4E076B",
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "CB2515B7-EBA0-4931-A8BD-64FF7424F952",
     "transform": {
      "values": [
       -0.45371049642562866,
       0,
       0.8911492228507996,
       0,
       0,
       1,
       0,
       0,
       -0.8911492228507996,
       0,
       -0.45371049642562866,
       0,
       6.565138816833496,
       -0.46548569202423096,
       3.0308077335357666,
       1
      ]
     }
    },
    {
     "category": "window",
     "confidence": "medium",
     "dimensions": {
      "x": 0.7851730585098267,
      "y": 1.956700086593628,
      "z": 0
     },
     "parentIdentifier": "C4DED968-AB83-4AA1-B644-6A162EFC1952",
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "9F5F5E23-B6A9-40FD-9A6C-621F98CB0BF8",
     "transform": {
      "values": [
       0.5713374614715576,
       0,
       -0.8207151889801025,
       0,
       0,
       1,
       0,
       0,
       0.8207151889801025,
       0,
       0.5713374614715576,
       0,
       -0.6889535784721375,
       -0.19924886524677277,
       -1.3175387382507324,
       1
      ]
     }
    },
    {
     "category": "opening",
     "confidence": "high",
     "dimensions": {
      "x": 0.7910917401313782,
      "y": 2.180000066757202,
      "z": 0
     },
     "parentIdentifier": "63C3D885-B5DA-48FB-8992-C9698DE294D1",
     "shapeHints": {
      "completedEdgeCount": 0,
      "hasCurve": false,
      "polygonCornerCount": 0
     },
     "sourceRoomPlanID": "2EB40120-C89C-47C5-B20F-9D3D9729EF12",
     "transform": {
      "values": [
       -0.8207152485847473,
       0,
       -0.5713375806808472,
       0,
       0,
       1,
       0,
       0,
       0.5713375806808472,
       0,
       -0.8207152485847473,
       0,
       5.903241157531738,
       -0.5268390774726868,
       4.966769218444824,
       1
      ]
     }
    }
   ]
  }
 ]
}
"""#
}
