import groovy.transform.Field
import org.jenkinsci.plugins.pipeline.modeldefinition.Utils
@Field def bundleTests = [:]

pipeline {
    agent none
    environment {
        TEST_CHANGES_SINCE_LAST_SUCCESSFUL = 'true'
        AUTOCORRECT = "${env.AUTOCORRECT ?: '0'}"
        AUTOCORRECT_CREDS = "${env.AUTOCORRECT_CREDS ?: 'github-token-rw'}"
        DEBUG = '1'
        BRANCH_PREFIX = 'v[0-9.]+'
        CASCGEN = './bin/cascgen'
        RANDOM_ADMIN_PASSWORD = "${System.currentTimeMillis()}"
        CASCTOOL_IMAGE = "${env.CASCTOOL_IMAGE ?: 'ghcr.io/kyounger/casc-plugin-dependency-calculation:v4.2.4'}"
    }
    options {
        timeout(90)
        skipStagesAfterUnstable()
        skipDefaultCheckout()
        disableConcurrentBuilds()
    }
    stages {
        stage('Preflight') {
            agent {
                kubernetes {
                    yaml getCascPodYaml(env.CASCTOOL_IMAGE)
                }
            }
            stages {
                stage('Verify') {
                    steps {
                        script { checkoutUtil() }
                        container('casctool') {
                            sh 'cascgen copyScripts bin'
                            sh 'ROOTS_COMMAND_FAIL_FAST=0 $CASCGEN roots verify || touch FAILED_VERIFICATION'
                        }
                    }
                }
                stage('Autocorrect') {
                    when {
                        expression { fileExists 'FAILED_VERIFICATION' }
                    }
                    steps {
                        container('casctool') {
                            withCredentials([gitUsernamePassword(credentialsId: 'sboardwell-simple-casc-bundles-rw', gitToolName: 'Default')]) {
                                sh '$CASCGEN autocorrect'
                            }
                            unstable 'This build has been stopped after autocorrecting the bundles.'
                        }
                    }
                }
                stage('Create Test Resources') {
                    steps {
                        container('casctool') {
                            sh '$CASCGEN roots createTestResources'
                            sh '$CASCGEN roots getChangedSources'
                            echo "Preflight checks were successful. No unexpected changes when generating the bundles."
                            script {
                                env.CI_IMAGE = sh(script: '$CASCGEN ciVersion', returnStdout: true).trim()
                                determineTestPlan()
                            }
                        }
                    }
                }
            }
        }
        stage('Tests') {
            when {
                expression { bundleTests.isEmpty() == false }
            }
            steps {
                script {
                    parallel(bundleTests)
                }
            }
        }
    }
}

def determineTestPlan() {
    def knownRoots = sh(script: '$CASCGEN roots', returnStdout: true).trim().split(' ')
    def currentChanged = ''
    def currentImage = ''
    for (String currentSubDir in knownRoots) {
        // Initial analysis to set NOT TESTED for all bundles in build description
        analyzeTestSummary(currentSubDir)
        currentChanged = readFile(getBundlePath('test-resources/.changed-effective-bundles', currentSubDir)).trim()
        currentImage = readFile(getBundlePath('test-resources/.ci-image', currentSubDir)).trim()
        def currentImageArg = currentImage.toString()
        def currentSubDirArg = currentSubDir.toString()
        echo "Current sub dir: $currentSubDirArg (currentChanged: $currentChanged)"
        if (currentChanged) {
            // Execute the test stage
            bundleTests[currentSubDir] = {
                stage(getSubDirStage("Main", currentSubDirArg)) {
                    podTemplate(yaml: getCascAndCiPodYaml(env.CASCTOOL_IMAGE, currentImageArg)) {
                        node(POD_LABEL) {
                            stage(getSubDirStage("Prep", currentSubDirArg)) {
                                checkoutUtil()
                                container('casctool') {
                                    sh 'cascgen copyScripts bin'
                                    sh '$CASCGEN roots createTestResources'
                                    sh '$CASCGEN roots getChangedSources'
                                }
                            }
                            stage(getSubDirStage("Test PR", currentSubDirArg)) {
                                if (env.CHANGE_ID) {
                                    withCredentials([string(credentialsId: 'casc-validation-key', variable: 'CASC_VALIDATION_LICENSE_KEY'), string(credentialsId: 'casc-validation-cert', variable: 'CASC_VALIDATION_LICENSE_CERT')]) {
                                        container('test-controller') {
                                            sh "BUNDLE_SUB_DIR=$currentSubDirArg $CASCGEN runValidationsChangedOnly"
                                            analyzeTestSummary(currentSubDirArg)
                                        }
                                    }
                                } else {
                                    Utils.markStageSkippedForConditional("Test Deltas $currentSubDirArg")
                                }
                            }
                            stage(getSubDirStage("Test Release", currentSubDirArg)) {
                                if (!env.CHANGE_ID) {
                                    withCredentials([string(credentialsId: 'casc-validation-key', variable: 'CASC_VALIDATION_LICENSE_KEY'), string(credentialsId: 'casc-validation-cert', variable: 'CASC_VALIDATION_LICENSE_CERT')]) {
                                        container('test-controller') {
                                            sh "BUNDLE_SUB_DIR=$currentSubDirArg $CASCGEN runValidationsChangedOnly"
                                            analyzeTestSummary(currentSubDirArg)
                                        }
                                    }
                                } else {
                                    Utils.markStageSkippedForConditional("Test All $currentSubDirArg")
                                }
                            }
                            stage(getSubDirStage("Deploy", currentSubDirArg)) {
                                echo "Decide if you wish to deploy the bundles..."
                                timeout(time:30, unit:'MINUTES') {
                                    if (BRANCH_NAME ==~ env.BRANCH_PREFIX) {
                                        echo "Found branch matching BRANCH_PREFIX..."
                                        String kustomizationPath = getBundlePath('effective-bundles/kustomization.yaml', currentSubDirArg)
                                        if (fileExists(kustomizationPath)) {
                                            echo "Decide if you wish to deploy the bundles from the kustomization.yaml below:"
                                            sh "echo 'Config map generator file: $kustomizationPath'; cat $kustomizationPath"
                                        } else {
                                            echo "No kustomization.yaml found for ${currentSubDirArg} at ${kustomizationPath}"
                                        }
                                    } else {
                                        echo "Did not find branch matching BRANCH_PREFIX...($BRANCH_NAME ==~ ${env.BRANCH_PREFIX})"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            // Skip the test stage
            bundleTests[currentSubDir] = {
                stage(getSubDirStage("Main", currentSubDirArg)) {
                    echo "Skipping ${STAGE_NAME}..."
                    Utils.markStageSkippedForConditional("Main $currentSubDirArg")
                    stage(getSubDirStage("Prep", currentSubDirArg)) {
                        echo "Skipping ${STAGE_NAME}..."
                        Utils.markStageSkippedForConditional("Prep $currentSubDirArg")
                    }
                    stage(getSubDirStage("Test Deltas", currentSubDirArg)) {
                        echo "Skipping ${STAGE_NAME}..."
                        Utils.markStageSkippedForConditional("Prep $currentSubDirArg")
                    }
                    stage(getSubDirStage("Test All", currentSubDirArg)) {
                        echo "Skipping ${STAGE_NAME}..."
                        Utils.markStageSkippedForConditional("Prep $currentSubDirArg")
                    }
                    stage(getSubDirStage("Deploy", currentSubDirArg)) {
                        echo "Skipping ${STAGE_NAME}..."
                        Utils.markStageSkippedForConditional("Prep $currentSubDirArg")
                    }
                }
            }
        }
    }
}

def checkoutUtil() {
    def gitArgs = checkout(scm)
    prettyPrint(gitArgs)
    for (def k in gitArgs.keySet()) {
        env."$k" = gitArgs[k]
    }
}

def getSubDirStage(def stageName, subDir) {
    return subDir == '.' ? stageName : "${stageName} ${subDir}"
}

def getBundlePath(def fileStr, String subDir = '') {
    return subDir ? "${subDir}/${fileStr}" : fileStr
}

def analyzeTestSummary(String subDir) {
    catchError(buildResult: 'UNSTABLE', message: 'Problems found with the bundles', stageResult: 'UNSTABLE') {
        container('casctool') {
            try {
                sh "BUNDLE_SUB_DIR='$subDir' \$CASCGEN getTestResultReport true"
            } finally {
                String testSummaryPath = getBundlePath('test-resources/test-summary.txt', subDir)
                if (fileExists(testSummaryPath)) {
                    echo "Adding test summary for ${subDir} from ${testSummaryPath}"
                    String testSummary = "${currentBuild.description ?: ''}" + readFile(getBundlePath('test-resources/test-summary.txt', subDir))
                    currentBuild.description = sortUniquely(testSummary)
                } else {
                    echo "No test summary found for ${subDir} at ${testSummaryPath}"
                }
            }
        }
    }
}

@NonCPS
def sortUniquely(String str) {
    Map map = new TreeMap()
    for (line in str.tokenize('\n').sort()) {
        def parts = line.tokenize(':')
        String bundle = parts[0]
        String status = parts[1].trim()
        if (map.containsKey(bundle)) {
            if (map[bundle].contains('NOT TESTED')) {
                map.put(bundle, line) // overwrite
            } else if (status.contains('NOT TESTED')) {
                continue
            } else {
                throw new Exception("Duplicate bundle found: ${bundle} (${map[bundle]} vs $line)")
            }
        } else {
            map.put(bundle, line)
        }
    }
    return map.values().join('\n')
}

@NonCPS
def prettyPrint(def obj) {
    if (obj instanceof Map) {
        println groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson((Map) obj))
    } else {
        println groovy.json.JsonOutput.prettyPrint(groovy.json.JsonOutput.toJson(obj))
    }
}

def getCascPodYaml(def casctoolImage) {
    return """\
    apiVersion: v1
    kind: Pod
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - image: $casctoolImage
        name: casctool
        command:
        - sleep
        args:
        - infinity
    """.stripIndent()
}

def getCascAndCiPodYaml(String casctoolImage, String ciImage) {
    return """\
    apiVersion: v1
    kind: Pod
    spec:
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
      - image: $casctoolImage
        name: casctool
        command:
        - sleep
        args:
        - infinity
      - image: ${ciImage}
        name: test-controller
        command:
        - sleep
        args:
        - infinity
        resources:
          requests:
            cpu: 1.5
            memory: 4Gi
    """.stripIndent()
}