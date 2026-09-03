sap.ui.define([
    "sap/ui/core/mvc/ControllerExtension",
    "sap/ui/core/Fragment",
    "sap/ui/core/Core",
    "sap/m/MessageToast",
    "sap/m/MessageBox"
], function (ControllerExtension, Fragment, Core, MessageToast, MessageBox) {
    "use strict";

    // Report types allowed to see the upload button (already uppercased for comparison)
    var ALLOWED_REPORT_TYPES = ["3. NA IN TRANSIT", "NA"];
    var REPORT_TYPE_KEYWORD = "NA IN TRANSIT";

    return ControllerExtension.extend("pipeline3.ext.controller.UploadExcel", {

        override: {
            onInit: function () {
                this._pDialog = null;
                this._oDialog = null;
                this._bFilterBarAttached = false;
                this._iRetryCount = 0;
                this._iMaxRetries = 10;
                this._iRetryDelayMs = 500;

                this._resetFilePayload();
            },

            onAfterRendering: function () {
                // Only wire up the FilterBar/button once; onAfterRendering can fire
                // multiple times but the listeners only need to be attached a single time.
                if (!this._bFilterBarAttached) {
                    this._initDynamicVisibility();
                }
            }
        },

        /* ---------------------------------------------------------------
         * File payload / uploader helpers
         * ------------------------------------------------------------- */

        /**
         * Clears the in-memory representation of the currently selected file.
         */
        _resetFilePayload: function () {
            this.filecontent = "";
            this.filetype = "";
            this.filename = "";
        },

        /**
         * Clears the FileUploader control (removing the selected file from the UI)
         * and resets the associated payload state kept on the controller instance.
         */
        _resetUploader: function () {
            var oFileUploader = this.base.getView().byId("IdFileUploader");
            if (oFileUploader) {
                oFileUploader.clear();
            }
            this._resetFilePayload();
        },

        /**
         * Collapses whitespace and normalizes case so report-type values coming
         * from different sources (typed text vs. selected key) can be compared reliably.
         */
        _normalizeText: function (vValue) {
            return String(vValue || "").replace(/\s+/g, " ").trim().toUpperCase();
        },

        /* ---------------------------------------------------------------
         * Success-text builder (result entity -> message -> static)
         * ------------------------------------------------------------- */

        /**
         * Builds the text shown to the user after a successful upload.
         * Preference order:
         *   1. The InsertedCount returned by the action's result entity (most accurate).
         *   2. The latest message raised by the backend (e.g. via BOPF/message class).
         *   3. A generic static fallback string.
         */
        _buildSuccessText: function (oContextBinding) {
            var oCtx = oContextBinding.getBoundContext && oContextBinding.getBoundContext();
            var oResult = oCtx && oCtx.getObject ? oCtx.getObject() : null;
            var iCount = oResult ? oResult.InsertedCount : undefined;

            // 1) Prefer the count returned in the action result entity
            if (iCount || iCount === 0) {
                return iCount + " record(s) uploaded successfully";
            }

            // 2) Fall back to any backend message, then to static text
            return this._getLatestBackendMessage("File uploaded successfully");
        },

        /**
         * Reads the most recent message raised by the backend via the SAPUI5
         * MessageManager (e.g. "12 record(s) uploaded successfully") and returns
         * it, or sFallback if no messages were raised. The message model is
         * cleared afterwards so stale messages from this call don't leak into
         * the next action's result handling.
         */
        _getLatestBackendMessage: function (sFallback) {
            var oMessageManager = Core.getMessageManager();
            var aMessages = oMessageManager.getMessageModel().getData() || [];
            var sText = sFallback;

            // Most recent message raised by the backend (e.g. "12 record(s) uploaded successfully")
            if (aMessages.length > 0) {
                sText = aMessages[aMessages.length - 1].message || sFallback;
            }

            // Clear so old messages don't leak into the next action
            oMessageManager.removeAllMessages();

            return sText;
        },

        /* ---------------------------------------------------------------
         * Dynamic upload-button visibility
         * ------------------------------------------------------------- */

        /**
         * Walks the view's control tree once to locate the FilterBar and the
         * upload Button. Both controls are looked up by traversal (rather than
         * a plain byId) because this is a controller *extension* and the
         * button/FilterBar live in the base view's fragments, which may not be
         * addressable via the extension's own view id.
         */
        _findControls: function () {
            var aControls = this.base.getView().findAggregatedObjects(true);
            var oFilterBar = null;
            var oUploadButton = null;
            var i;
            var oCtrl;
            var sId;

            for (i = 0; i < aControls.length; i++) {
                oCtrl = aControls[i];

                if (!oFilterBar && oCtrl.isA("sap.ui.mdc.FilterBar")) {
                    oFilterBar = oCtrl;
                }

                if (!oUploadButton && oCtrl.isA("sap.m.Button")) {
                    sId = oCtrl.getId();
                    if (sId && sId.indexOf("IdUploadExcel") !== -1) {
                        oUploadButton = oCtrl;
                    }
                }

                if (oFilterBar && oUploadButton) {
                    break;
                }
            }

            return { filterBar: oFilterBar, uploadButton: oUploadButton };
        },

        /**
         * Attempts to find the FilterBar/upload button and wire up visibility
         * handling. The FilterBar is rendered asynchronously by the flexible
         * column layout/list report template, so it may not exist yet on the
         * first onAfterRendering call - this retries with a short delay (up to
         * _iMaxRetries times) until both controls are found.
         */
        _initDynamicVisibility: function () {
            var oRefs = this._findControls();

            if (oRefs.filterBar && oRefs.uploadButton) {
                this._attachFilterBarListeners(oRefs.filterBar, oRefs.uploadButton);
                this._bFilterBarAttached = true;
                this._toggleUploadButton(oRefs.filterBar, oRefs.uploadButton);
                return;
            }

            if (this._iRetryCount < this._iMaxRetries) {
                this._iRetryCount += 1;
                window.setTimeout(this._initDynamicVisibility.bind(this), this._iRetryDelayMs);
            }
        },

        /**
         * Re-evaluates the upload button's visibility whenever the FilterBar's
         * conditions change or a search is triggered, so the button reacts live
         * to the user changing the Report Type filter.
         */
        _attachFilterBarListeners: function (oFilterBar, oUploadButton) {
            var fnUpdate = this._toggleUploadButton.bind(this, oFilterBar, oUploadButton);

            if (typeof oFilterBar.attachFiltersChanged === "function") {
                oFilterBar.attachFiltersChanged(fnUpdate);
            }

            if (typeof oFilterBar.attachSearch === "function") {
                oFilterBar.attachSearch(fnUpdate);
            }
        },

        /**
         * Extracts a single usable value out of an mdc FilterBar condition object,
         * which can hold a primitive, a value-help object ({key, value, description, text}),
         * or a plain {value/key/description/text} shape depending on the field's type.
         */
        _extractConditionValue: function (oCondition) {
            var oFirst;

            if (!oCondition) {
                return "";
            }

            if (oCondition.values && oCondition.values.length > 0) {
                oFirst = oCondition.values[0];

                if (typeof oFirst === "string" || typeof oFirst === "number") {
                    return String(oFirst);
                }

                if (oFirst && typeof oFirst === "object") {
                    return String(oFirst.key || oFirst.value || oFirst.description || oFirst.text || "");
                }
            }

            return String(oCondition.value || oCondition.key || oCondition.description || oCondition.text || "");
        },

        /**
         * Reads the currently selected "Report Type" filter value from the
         * FilterBar's conditions map. The field name is matched with a
         * case-insensitive regex (rather than a fixed key) because the mdc
         * FilterBar's condition keys are derived from the annotation-defined
         * field name, which can vary in casing/prefix across services.
         */
        _getReportTypeValue: function (oFilterBar) {
            var oConditions;
            var aKeys;
            var i;
            var sKey;
            var aConditions;
            var sValue;

            if (!oFilterBar || typeof oFilterBar.getConditions !== "function") {
                return "";
            }

            oConditions = oFilterBar.getConditions();
            if (!oConditions) {
                return "";
            }

            aKeys = Object.keys(oConditions);

            for (i = 0; i < aKeys.length; i++) {
                sKey = aKeys[i];

                if (/reporttype/i.test(sKey)) {
                    aConditions = oConditions[sKey];

                    if (aConditions && aConditions.length > 0) {
                        sValue = this._extractConditionValue(aConditions[0]);
                        if (sValue) {
                            return sValue;
                        }
                    }
                }
            }

            return "";
        },

        /**
         * The upload button should only be shown for the "NA in transit" report.
         * Checked against both the exact allow-listed values and a keyword
         * match, since the Report Type value may arrive either as the full
         * display text ("3. NA In Transit") or a shorter variant.
         */
        _isUploadAllowedForReportType: function (sReportType) {
            var sNormalized = this._normalizeText(sReportType);

            return ALLOWED_REPORT_TYPES.indexOf(sNormalized) !== -1 ||
                sNormalized.indexOf(REPORT_TYPE_KEYWORD) !== -1;
        },

        /**
         * Shows/hides the upload button based on the FilterBar's current Report
         * Type selection. Wrapped in try/catch because the FilterBar's condition
         * shape is not part of a stable public API and could change or throw on
         * an unsupported field type - in that case the button is simply hidden.
         */
        _toggleUploadButton: function (oFilterBar, oUploadButton) {
            var bShowButton = false;

            try {
                bShowButton = this._isUploadAllowedForReportType(this._getReportTypeValue(oFilterBar));
            } catch (oError) {
                console.warn("Could not evaluate FilterBar conditions", oError);
            }

            oUploadButton.setVisible(bShowButton);
        },

        /* ---------------------------------------------------------------
         * Dialog lifecycle
         * ------------------------------------------------------------- */

        /**
         * Lazily loads (once) and caches the upload dialog fragment, adding it
         * as a dependent of the view so it participates in the view's lifecycle
         * (e.g. destroyed together with the view).
         */
        _getDialog: function () {
            var oView = this.base.getView();

            if (!this._pDialog) {
                this._pDialog = Fragment.load({
                    id: oView.getId(),
                    name: "pipeline3.ext.fragment.filedialog",
                    controller: this
                }).then(function (oDialog) {
                    oView.addDependent(oDialog);
                    this._oDialog = oDialog;
                    return oDialog;
                }.bind(this));
            }

            return this._pDialog;
        },

        /**
         * Entry point wired to the "Upload Excel" button; opens the file-upload dialog.
         */
        UploadExcel: function () {
            this._getDialog().then(function (oDialog) {
                oDialog.open();
            }).catch(function (oError) {
                MessageBox.error("Dialog could not be opened: " + oError.message);
            });
        },

        onUploadCancel: function () {
            if (this._oDialog) {
                this._oDialog.close();
            }
            this._resetUploader();
        },

        /* ---------------------------------------------------------------
         * CSV template download
         * ------------------------------------------------------------- */

        /**
         * Wraps a value in double quotes and escapes any embedded quotes,
         * per RFC 4180, so header names containing commas/quotes stay valid CSV.
         */
        _escapeCsvValue: function (vValue) {
            var sValue = vValue === null || vValue === undefined ? "" : String(vValue);
            return "\"" + sValue.replace(/"/g, "\"\"") + "\"";
        },

        /**
         * Builds the empty CSV template (header row only) that users download
         * and fill in before uploading. The leading "﻿" is a UTF-8 BOM so
         * Excel recognizes the file's encoding and does not mangle special characters.
         */
        _buildTemplateCsv: function () {
            var aHeaders = ["Plant", "Legacy Supplier", "Dock", "Route", "Last Order Unloaded"];
            return "﻿" + aHeaders.map(this._escapeCsvValue, this).join(",") + "\r\n";
        },

        /**
         * Triggers a client-side file download for arbitrary text content by
         * creating a temporary Blob URL and a hidden anchor click, since there
         * is no server endpoint serving the static template file.
         */
        _downloadFile: function (sContent, sFileName, sMimeType) {
            var oBlob = new Blob([sContent], { type: sMimeType });
            var sUrl = URL.createObjectURL(oBlob);
            var oLink = document.createElement("a");

            oLink.href = sUrl;
            oLink.download = sFileName;
            document.body.appendChild(oLink);
            oLink.click();
            document.body.removeChild(oLink);
            URL.revokeObjectURL(sUrl);
        },

        DownloadNaFile: function () {
            this._downloadFile(this._buildTemplateCsv(), "NA_Upload_Template.csv", "text/csv;charset=utf-8;");
            MessageToast.show("Template downloaded successfully");
        },

        /* ---------------------------------------------------------------
         * File selection
         * ------------------------------------------------------------- */

        /**
         * Reads a File as a base64 string via FileReader's data URL result,
         * stripping the "data:<mime>;base64," prefix so only the raw base64
         * payload (as expected by the OData action parameter) remains.
         */
        _readFileAsBase64: function (oFile) {
            return new Promise(function (resolve, reject) {
                var oReader = new FileReader();

                oReader.onload = function (oEvent) {
                    var sResult = oEvent.target.result || "";
                    resolve(sResult.split(",")[1] || "");
                };

                oReader.onerror = function () {
                    reject(new Error("Failed to read the selected file."));
                };

                oReader.readAsDataURL(oFile);
            });
        },

        /**
         * Handles the FileUploader's file selection: captures name/type
         * immediately, then asynchronously reads and stores the base64 content
         * used later by onUploadPress. Resets any previously selected file first
         * so a failed read never leaves a stale/mismatched payload behind.
         */
        onFileChange: function (oEvent) {
            var aFiles = oEvent.getParameter("files");
            var oFile = aFiles && aFiles[0];

            this._resetFilePayload();

            if (!oFile) {
                MessageBox.error("No file selected.");
                return;
            }

            this.filename = oFile.name;
            this.filetype = oFile.type || "application/octet-stream";

            this._readFileAsBase64(oFile).then(function (sBase64) {
                this.filecontent = sBase64;
                MessageToast.show("Selected: " + this.filename);
            }.bind(this)).catch(function (oError) {
                this._resetFilePayload();
                MessageBox.error(oError.message);
            }.bind(this));
        },

        /* ---------------------------------------------------------------
         * Upload action
         * ------------------------------------------------------------- */

        /**
         * Guards against invoking the upload OData action with an incomplete
         * payload, e.g. because the file is still being read asynchronously by
         * _readFileAsBase64 when the user clicks Upload.
         */
        _validateUploadPayload: function () {
            if (!this.filename) {
                MessageBox.error("Please select a file before uploading.");
                return false;
            }

            if (!this.filetype) {
                MessageBox.error("File type is missing.");
                return false;
            }

            if (!this.filecontent) {
                MessageBox.error("File content is still loading or missing.");
                return false;
            }

            return true;
        },

        /**
         * Creates the deferred/bound action-import context binding for
         * UploadNaFile and populates its parameters from the currently
         * selected file.
         */
        _createUploadActionBinding: function () {
            var oModel = this.base.getView().getModel();
            var oContextBinding = oModel.bindContext(
                "/ZCE_Pipleline_report/com.sap.gateway.srvd.zsd_pipelienreport.v0001.UploadNaFile(...)"
            );

            oContextBinding.setParameter("FileName", this.filename);
            oContextBinding.setParameter("MimeType", this.filetype);
            oContextBinding.setParameter("FileContent", this.filecontent);

            return oContextBinding;
        },

        /**
         * Executes the action binding, tolerating both the newer "invoke" and
         * older "execute" API names so this works across different versions
         * of the OData V4 model.
         */
        _executeAction: function (oContextBinding) {
            if (typeof oContextBinding.invoke === "function") {
                return oContextBinding.invoke();
            }

            if (typeof oContextBinding.execute === "function") {
                return oContextBinding.execute();
            }

            return Promise.reject(new Error("OData action binding does not support invoke or execute."));
        },

        /**
         * Handles the "Upload" button press in the dialog: validates the
         * selected file, invokes the backend UploadNaFile action, and reports
         * success/failure back to the user, cleaning up the dialog/uploader
         * state on success only (so the user can retry on failure without
         * re-selecting the file).
         */
        onUploadPress: function () {
            var oContextBinding;

            if (!this._validateUploadPayload()) {
                return;
            }

            oContextBinding = this._createUploadActionBinding();

            this._executeAction(oContextBinding).then(function () {
                // Count from result entity -> backend message -> static text
                MessageToast.show(this._buildSuccessText(oContextBinding));

                if (this._oDialog) {
                    this._oDialog.close();
                }

                this._resetUploader();
            }.bind(this)).catch(function (oError) {
                MessageBox.error("File upload failed: " + this._getLatestBackendMessage(oError.message));
            }.bind(this));
        },

        onUploadComplete: function () {
            MessageToast.show("Upload complete");
        }
    });
});
