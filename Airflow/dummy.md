import json
import subprocess
import tempfile


class AtlasPublisher:

    def __init__(self,atlas_url):

        self.atlas_url = atlas_url.rstrip("/")


    def post_entity(self,payload):

        subprocess.run(["klist"])

        with tempfile.NamedTemporaryFile(
            mode="w",
            delete=False
        ) as f:

            json.dump(payload,f)

            file_name=f.name


        cmd=[

            "curl",

            "--negotiate",

            "-u",":",

            "-k",

            "-H","Content-Type: application/json",

            "-X","POST",

            f"{self.atlas_url}/api/atlas/v2/entity",

            "-d",f"@{file_name}"

        ]


        result=subprocess.run(
            cmd,
            capture_output=True,
            text=True
        )

        print(result.stdout)

        if result.returncode !=0:

            raise Exception(result.stderr)



    def publish_table_lineage(self,model):


        ##################################
        # SOURCE DATASET
        ##################################

        source_payload={

            "entity":{

                "typeName":model["source_type"],

                "attributes":{

                    "name":
                    model["source_name"],

                    "qualifiedName":
                    model["source_qn"]
                }
            }
        }



        ##################################
        # TARGET
        ##################################

        target_payload={

            "entity":{

                "typeName":model["target_type"],

                "attributes":{

                    "name":
                    model["target_name"],

                    "qualifiedName":
                    model["target_qn"]
                }
            }
        }



        ##################################
        # PROCESS
        ##################################

        process_payload={

            "entity":{

                "typeName":"Process",

                "attributes":{

                    "name":
                    model["process_name"],

                    "qualifiedName":
                    model["process_qn"],


                    "inputs":[

                        {

                            "typeName":
                            model["source_type"],

                            "uniqueAttributes":{

                                "qualifiedName":
                                model["source_qn"]
                            }
                        }
                    ],


                    "outputs":[

                        {

                            "typeName":
                            model["target_type"],

                            "uniqueAttributes":{

                                "qualifiedName":
                                model["target_qn"]
                            }
                        }
                    ]
                }
            }
        }



        ##################################
        # ORDER
        ##################################

        print("Publishing source")

        self.post_entity(source_payload)


        print("Publishing target")

        self.post_entity(target_payload)


        print("Publishing process")

        self.post_entity(process_payload)