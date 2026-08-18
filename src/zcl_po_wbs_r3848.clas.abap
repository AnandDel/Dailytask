*//----------------------------------------------------------------------*
*--*&  author          : anand bajpai                                      *
*--*&  creation date   : 10/12/2025                                        *
*--*&  ricefw-id       : R-3848                                            *
*--*&  description     : po wbs tax report                                 *
*--*&----------------------------------------------------------------------*
*--*& modifications                                                        *
*--*&  user id     date           transport/description                    *
*--*&  607231     10/12/2025    sd4k920285 /initial Implementation         *
*--*&  607231     18/08/2026    sd4k920xxx /join RBKP on BELNR + GJAHR     *
*--*&                            (via FiscalYear from                     *
*--*&                            i_suplrinvcitempurordrefapi01) instead   *
*--*&                            of BELNR alone, to avoid matching        *
*--*&                            invoice documents from unrelated fiscal  *
*--*&                            years                                    *
*--*&  607231     18/08/2026    sd4k920xxx /push the project's PO/OBJNR   *
*--*&                            scope down into the COOI, AFVU, RESB and *
*--*&                            invoice-reference lookups (steps 3,4,5,9)*
*--*&                            instead of scanning those sources        *
*--*&                            unfiltered and relying on the later      *
*--*&                            LEFT JOIN to discard irrelevant rows     *
*--*&----------------------------------------------------------------------*
*--*&
*--*&----------------------------------------------------------------------*
CLASS zcl_po_wbs_r3848 DEFINITION
 PUBLIC
  FINAL
  CREATE PUBLIC .

  PUBLIC SECTION.

    " Define structure for final output
    TYPES: BEGIN OF ty_final,
             mandt          TYPE char3,
             pspid_edit     TYPE proj-pspid_edit,
             posid_edit     TYPE prps-posid_edit,
             zzwarpponumber TYPE prps-zzwarpponumber,
             ebeln          TYPE ekpo-ebeln,
             brtwr          TYPE ekpo-brtwr,
             zzidnumber     TYPE afvu-zzidnumber,
             zzpartnumber   TYPE prps-zzpartnumber,
             wempf          TYPE resb-wempf,
             rmwwr          TYPE rbkp-rmwwr,
             wmwst1         TYPE rbkp-wmwst1,
             wmwst2         TYPE rbkp-wmwst1,
             whgbtr         TYPE cooi-whgbtr,
             whgbtr1        TYPE cooi-whgbtr,
             whgbtr2        TYPE cooi-whgbtr,
             loekz          TYPE ekpo-loekz,
             banfn          TYPE ekpo-banfn,
             belnr          TYPE rbkp-belnr,
             gjahr          TYPE rbkp-gjahr,
             blart          TYPE rbkp-blart,
             bldat          TYPE rbkp-bldat,
             budat          TYPE rbkp-budat,
             usnam          TYPE rbkp-usnam,
             tcode          TYPE rbkp-tcode,
             cpudt          TYPE rbkp-cpudt,
             cputm          TYPE rbkp-cputm,
             vgart          TYPE rbkp-vgart,
             xblnr          TYPE rbkp-xblnr,
             bukrs          TYPE rbkp-bukrs,
             lifnr          TYPE rbkp-lifnr,
             waers          TYPE rbkp-waers,
             kursf          TYPE rbkp-kursf,
             beznk          TYPE rbkp-beznk,
             txdat          TYPE rbkp-txdat,
             txdat_from     TYPE rbkp-txdat_from,
             mwskz1         TYPE rbkp-mwskz1,
             zterm          TYPE rbkp-zterm,
             zbd1t          TYPE rbkp-zbd1t,
             bktxt          TYPE rbkp-bktxt,
             saprl          TYPE rbkp-saprl,
             logsys         TYPE rbkp-logsys,
             xmwst          TYPE rbkp-xmwst,
             stblg          TYPE rbkp-stblg,
             stjah          TYPE rbkp-stjah,
             mwskz_bnk      TYPE rbkp-mwskz_bnk,
             txjcd_bnk      TYPE rbkp-txjcd_bnk,
             ivtyp          TYPE rbkp-ivtyp,
             xrbtx          TYPE rbkp-xrbtx,
             repart         TYPE rbkp-repart,
             rbstat         TYPE rbkp-rbstat,
           END OF ty_final,

           " Table type for output
           tt_final_data TYPE STANDARD TABLE OF ty_final.

    " AMDP marker interface
    INTERFACES if_amdp_marker_hdb.

    CLASS-METHODS fetch_data FOR TABLE FUNCTION ztf_po_wbs_r3848.

  PROTECTED SECTION.
  PRIVATE SECTION.

ENDCLASS.

CLASS zcl_po_wbs_r3848 IMPLEMENTATION.

METHOD fetch_data BY DATABASE FUNCTION FOR HDB
  LANGUAGE SQLSCRIPT
  OPTIONS READ-ONLY
  USING zr_rbkp_atc
        zr_prps_atc
        zr_proj_atc
        zcds_ptp_cooi_tbdp
        zr_ekpo_atc
        zr_afvu_atc
        zr_resb_atc
        zr_afvc_atc
        I_PurOrdAccountAssignmentAPI01
        i_suplrinvcitempurordrefapi01
        zr_aufk_atc.

  ----------------------------------------------------------------------
  -- 1. Select project level-4 WBS elements
  ----------------------------------------------------------------------
  it_prps =
    SELECT
      pr.mandt,
      pr.objnr,
      pr.zzwarpponumber,
      pr.psphi,
      pr.posidedit AS posid_edit,
      pr.zzpartnumber,
      pr.pspnr,
      pr.pbukr AS bukrs,
      proj.pspid_edit
    FROM zr_prps_atc AS pr
    INNER JOIN zr_proj_atc AS proj
      ON  proj.pspnr = pr.psphi
      AND proj.mandt = pr.mandt
    WHERE pr.mandt = :p_client
      AND pr.stufe = 4
      AND proj.pspid_edit = :p_project;


  ----------------------------------------------------------------------
  -- 2. Map WBS elements to networks and purchase orders
  --
  -- WBS-to-network relationship:
  -- AUFK-PSPEL = PRPS-PSPNR
  --
  -- The LEFT OUTER JOIN keeps WBS rows even when the API does not
  -- return a matching purchase order.
  ----------------------------------------------------------------------
  it_nplnr =
    SELECT DISTINCT
      pr.mandt,
      pr.psphi,
      pr.pspnr,
      aufk.aufnr,
      ekkn.projectnetwork AS nplnr,
      ekkn.purchaseorder AS ebeln,
      aufk.pspel
    FROM :it_prps AS pr
    LEFT OUTER JOIN zr_aufk_atc AS aufk
      ON aufk.pspel = pr.pspnr
    LEFT OUTER JOIN I_PurOrdAccountAssignmentAPI01 AS ekkn
      ON ekkn.projectnetwork = aufk.aufnr;


  ----------------------------------------------------------------------
  -- 2a. Scope: distinct PO numbers relevant to this project
  --
  -- Reused below to cut RESB and the invoice-reference API down to
  -- just this project's purchase orders instead of scanning every PO
  -- in the system before the LEFT JOIN in step 10 discards the rest.
  ----------------------------------------------------------------------
  it_ebeln_scope =
    SELECT DISTINCT ebeln
    FROM :it_nplnr
    WHERE ebeln IS NOT NULL
      AND ebeln <> '';


  ----------------------------------------------------------------------
  -- 3. Aggregate existing COOI values
  --
  -- This uses the existing custom COOI source only.
  -- REFΒT = '020' is retained from the original implementation.
  --
  -- Filtered to this project's OBJNR values (from it_prps) so the
  -- aggregation doesn't sum COOI rows for every other project first.
  ----------------------------------------------------------------------
  it_cooi =
    SELECT
      objnr,
      SUM( whgbtr ) AS whgbtr
    FROM zcds_ptp_cooi_tbdp
    WHERE refbt = '020'
      AND objnr IN ( SELECT objnr FROM :it_prps )
    GROUP BY objnr;


  ----------------------------------------------------------------------
  -- 4. Read operation ID-number assignments
  --
  -- Filtered to the network numbers that can actually match this
  -- project's WBS elements (see the RIGHT(objnr, 8) join in step 6)
  -- instead of reading every network's operations system-wide.
  ----------------------------------------------------------------------
  it_afvu =
    SELECT DISTINCT
      afvc.projn,
      afvu.usr03,
      afvu.zzidnumber
    FROM zr_afvc_atc AS afvc
    INNER JOIN zr_afvu_atc AS afvu
      ON  afvu.aufpl = afvc.aufpl
      AND afvu.aplzl = afvc.aplzl
    WHERE afvu.usr03 IS NOT NULL
      AND afvu.usr03 <> ''
      AND afvc.projn IN ( SELECT RIGHT( objnr, 8 ) FROM :it_prps );


  ----------------------------------------------------------------------
  -- 5. Read reservation recipient data
  --
  -- Filtered to this project's PO scope (it_ebeln_scope) instead of
  -- reading RESB for every PO in the system.
  ----------------------------------------------------------------------
  it_resb =
    SELECT DISTINCT
      ebeln,
      wempf
    FROM zr_resb_atc
    WHERE ebeln IS NOT NULL
      AND ebeln <> ''
      AND ebeln IN ( SELECT ebeln FROM :it_ebeln_scope );


  ----------------------------------------------------------------------
  -- 6. Combine WBS, PO, COOI, and AFVU data
  ----------------------------------------------------------------------
  it_prps_1 =
    SELECT DISTINCT
      pr.mandt,
      pr.objnr,
      nplnr.ebeln,
      pr.pspid_edit,
      pr.posid_edit,
      pr.zzwarpponumber,
      pr.zzpartnumber,
      pr.psphi,
      pr.bukrs,
      COALESCE( cooi.whgbtr, 0 ) AS whgbtr,
      afvu.zzidnumber
    FROM :it_prps AS pr
    LEFT OUTER JOIN :it_nplnr AS nplnr
      ON  nplnr.mandt = pr.mandt
      AND nplnr.psphi = pr.psphi
      AND nplnr.pspnr = pr.pspnr
    LEFT OUTER JOIN :it_cooi AS cooi
      ON cooi.objnr = pr.objnr
    LEFT OUTER JOIN :it_afvu AS afvu
      ON  afvu.projn = RIGHT( pr.objnr, 8 )
      AND afvu.usr03 = pr.zzwarpponumber;


  ----------------------------------------------------------------------
  -- 7. Create unique PO keys
  ----------------------------------------------------------------------
  it_po_keys =
    SELECT DISTINCT
      mandt,
      ebeln,
      pspid_edit,
      posid_edit
    FROM :it_prps_1
    WHERE ebeln IS NOT NULL
      AND ebeln <> '';


  ----------------------------------------------------------------------
  -- 8. Aggregate PO item values
  ----------------------------------------------------------------------
  it_po_total =
    SELECT
      keys.mandt,
      keys.ebeln,
      keys.pspid_edit,
      keys.posid_edit,
      COALESCE( SUM( ekpo.brtwr ), 0 ) AS brtwr,
      MIN( ekpo.loekz ) AS loekz,
      MIN( ekpo.banfn ) AS banfn
    FROM :it_po_keys AS keys
    LEFT OUTER JOIN zr_ekpo_atc AS ekpo
      ON ekpo.purchaseorder = keys.ebeln
    GROUP BY
      keys.mandt,
      keys.ebeln,
      keys.pspid_edit,
      keys.posid_edit;


  ----------------------------------------------------------------------
  -- 9. Read supplier invoice references
  --
  -- FIX: FiscalYear is now carried alongside the PO/invoice keys so
  -- RBKP can be joined on BELNR + GJAHR in step 10 instead of BELNR
  -- alone (invoice document numbers repeat across fiscal years).
  -- SupplierInvoiceItem is intentionally NOT selected here - adding it
  -- would make this SELECT DISTINCT produce one row per invoice line
  -- instead of one row per (PO, invoice), re-fanning-out the RBKP
  -- header join for any invoice with multiple lines against the PO.
  --
  -- Filtered to this project's PO scope (it_ebeln_scope) instead of
  -- reading every purchase-order/invoice reference in the system.
  ----------------------------------------------------------------------
  it_invoice_reference =
    SELECT DISTINCT
      purchaseorder,
      supplierinvoice,
      FiscalYear
    FROM i_suplrinvcitempurordrefapi01
    WHERE purchaseorder IS NOT NULL
      AND purchaseorder <> ''
      AND supplierinvoice IS NOT NULL
      AND supplierinvoice <> ''
      AND purchaseorder IN ( SELECT ebeln FROM :it_ebeln_scope );


  ----------------------------------------------------------------------
  -- 10. Build final report data
  ----------------------------------------------------------------------
  it_data =
    SELECT DISTINCT
      pr.mandt,
      pr.pspid_edit,
      pr.posid_edit,
      pr.zzwarpponumber,
      pr.ebeln,
      pr.zzidnumber,
      COALESCE( po.brtwr, 0 ) AS brtwr,
      pr.zzpartnumber,
      resb.wempf,

      COALESCE( rbkp.rmwwr, 0 ) AS rmwwr,
      COALESCE( rbkp.wmwst1, 0 ) AS wmwst1,

      COALESCE( rbkp.rmwwr, 0 )
        - COALESCE( rbkp.wmwst1, 0 ) AS wmwst2,

      COALESCE( pr.whgbtr, 0 ) AS whgbtr,

      COALESCE( pr.whgbtr, 0 )
        + COALESCE( rbkp.rmwwr, 0 ) AS whgbtr1,

      COALESCE( po.brtwr, 0 )
        - COALESCE( rbkp.rmwwr, 0 ) AS whgbtr2,

      po.loekz,
      po.banfn,

      rbkp.belnr,
      rbkp.gjahr,
      rbkp.blart,
      rbkp.bldat,
      rbkp.budat,
      rbkp.usnam,
      rbkp.tcode,
      rbkp.cpudt,
      rbkp.cputm,
      rbkp.vgart,
      rbkp.xblnr,

      pr.bukrs,

      rbkp.lifnr,
      rbkp.waers,
      rbkp.kursf,
      rbkp.beznk,
      rbkp.txdat,
      rbkp.txdatfrom AS txdat_from,
      rbkp.mwskz1,
      rbkp.zterm,
      rbkp.zbd1t,
      rbkp.bktxt,
      rbkp.saprl,
      rbkp.logsys,
      rbkp.xmwst,
      rbkp.stblg,
      rbkp.stjah,
      rbkp.mwskzbnk AS mwskz_bnk,
      rbkp.txjcdbnk AS txjcd_bnk,
      rbkp.ivtyp,
      rbkp.xrbtx,
      rbkp.repart,
      rbkp.rbstat

    FROM :it_prps_1 AS pr
    LEFT OUTER JOIN :it_po_total AS po
      ON  po.mandt = pr.mandt
      AND po.ebeln = pr.ebeln
      AND po.pspid_edit = pr.pspid_edit
      AND po.posid_edit = pr.posid_edit
    LEFT OUTER JOIN :it_invoice_reference AS inv_ref
      ON inv_ref.purchaseorder = pr.ebeln
    LEFT OUTER JOIN zr_rbkp_atc AS rbkp
      ON  rbkp.belnr = inv_ref.supplierinvoice
      AND rbkp.gjahr = inv_ref.fiscalyear
    LEFT OUTER JOIN :it_resb AS resb
      ON resb.ebeln = pr.ebeln
    WHERE pr.mandt = :p_client
      AND pr.pspid_edit IS NOT NULL
      AND pr.pspid_edit <> '';


  ----------------------------------------------------------------------
  -- 11. Return table-function output
  ----------------------------------------------------------------------
  RETURN
    SELECT
      mandt,
      SYSUUID AS id,
      pspid_edit,
      posid_edit,
      zzwarpponumber,
      ebeln,
      zzidnumber,
      brtwr,
      zzpartnumber,
      wempf,
      rmwwr,
      wmwst1,
      wmwst2,
      whgbtr,
      whgbtr1,
      whgbtr2,
      loekz,
      banfn,
      belnr,
      gjahr,
      blart,
      bldat,
      budat,
      usnam,
      tcode,
      cpudt,
      cputm,
      vgart,
      xblnr,
      bukrs,
      lifnr,
      waers,
      kursf,
      beznk,
      txdat,
      txdat_from,
      mwskz1,
      zterm,
      zbd1t,
      bktxt,
      saprl,
      logsys,
      xmwst,
      stblg,
      stjah,
      mwskz_bnk,
      txjcd_bnk,
      ivtyp,
      xrbtx,
      repart,
      rbstat
    FROM :it_data;

ENDMETHOD.



ENDCLASS.
